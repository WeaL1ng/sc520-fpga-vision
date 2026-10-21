#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mdlink.py —— 医学数据 / 抓拍图片上传通道的 PC 端接收与可视化工具

配套 FPGA 侧协议见 doc/analysis/网络模块-方案（缩窄版）.md。
本工具只用标准库（socket / struct / csv / argparse / time），
不依赖 pyserial / matplotlib / numpy；若安装了它们会自动启用增强功能。

三种用法
--------
1) 自测（不需要 FPGA，验证协议与 PC 端逻辑）
     python mdlink.py --selftest

2) 监听 UDP（FPGA 以太网通道）
     python mdlink.py --udp --port 5000

3) 监听串口（FPGA UART 通道，需要 pyserial）
     python mdlink.py --serial COM3 --baud 921600

产物
----
  out/telemetry.csv   所有遥测记录（status/detect/motion/vital）
  out/img_*.bin       抓拍图片（按帧序号命名）
  out/live.txt        实时状态快照（给不装 GUI 的终端看）
"""

import argparse
import csv
import os
import struct
import sys
import time

# ---------------------------------------------------------------- 协议常量

MAGIC = 0x4D44           # 'MD'
VERSION = 0x01
UART_SYNC = b"\xAA\x55"
UART_MAX_PAYLOAD = 1024

TYPE_STATUS = 0x01
TYPE_DETECT = 0x02
TYPE_MOTION = 0x03
TYPE_VITAL = 0x04
TYPE_IMAGE = 0x05

TYPE_NAME = {
    TYPE_STATUS: "STATUS",
    TYPE_DETECT: "DETECT",
    TYPE_MOTION: "MOTION",
    TYPE_VITAL:  "VITAL",
    TYPE_IMAGE:  "IMAGE",
}

IMG_FMT_NAME = {0: "RGB565", 1: "RGB888", 2: "GRAY8"}

TLM_HEADER = struct.Struct("<HBBHIHBBH")    # 16 B
#   magic u16, version u8, type u8, frame_id u16,
#   ts_ms u32, latency_ms u16, mode u8, flags u8, body_len u16

STATUS = struct.Struct("<HHHHHBBI")           # 16 B
DETECT = struct.Struct("<BBHHHHHHBB I")       # 24 B
MOTION = struct.Struct("<HHHHHHHH")           # 16 B
VITAL  = struct.Struct("<HHHBB HHHH")         # 16 B
IMGHDR = struct.Struct("<HHHHBBBB")           # 12 B
#   frame_seq u16, chunk_idx u16, chunk_total u16,
#   width u16, height u16, format u8, flags u8, reserved u8


def crc16_ccitt(data: bytes, crc: int = 0xFFFF) -> int:
    """CRC16-CCITT (poly 0x1021, init 0xFFFF, no reflection, no final xor)."""
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if (crc & 0x8000) else (crc << 1) & 0xFFFF
    return crc


# ---------------------------------------------------------------- 解析

class Telemetry:
    __slots__ = (
        # 头
        "magic", "version", "type", "frame_id", "ts_ms", "latency_ms",
        "mode", "flags", "body_len", "body", "recv_t",
        # type=STATUS
        "luma_mean", "clip_permille", "ae", "ag", "fps_x10",
        "status_bits", "reserved", "drop_cnt",
        # type=DETECT
        "class_id", "count", "x0", "y0", "x1", "y1",
        "fill_permille", "area_px", "shape_id", "reserved2",
        # type=MOTION
        "motion_count", "motion_th", "tiles_hit",
        # type=VITAL
        "hr_x10", "roi_mean", "roi_ac", "quality", "roi_id",
        "rx0", "ry0", "rx1", "ry1",
    )

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))

    def decode_body(self):
        try:
            if self.type == TYPE_STATUS and len(self.body) >= STATUS.size:
                (self.luma_mean, self.clip_permille, self.ae, self.ag,
                 self.fps_x10, self.status_bits, self.reserved,
                 self.drop_cnt) = STATUS.unpack_from(self.body)
            elif self.type == TYPE_DETECT and len(self.body) >= DETECT.size:
                (self.class_id, self.count, self.x0, self.y0, self.x1, self.y1,
                 self.fill_permille, self.area_px, self.shape_id, self.reserved,
                 self.reserved2) = DETECT.unpack_from(self.body)
            elif self.type == TYPE_MOTION and len(self.body) >= MOTION.size:
                (self.motion_count, self.x0, self.y0, self.x1, self.y1,
                 self.motion_th, self.tiles_hit, self.reserved) = MOTION.unpack_from(self.body)
            elif self.type == TYPE_VITAL and len(self.body) >= VITAL.size:
                (self.hr_x10, self.roi_mean, self.roi_ac,
                 self.quality, self.roi_id,
                 self.rx0, self.ry0, self.rx1, self.ry1) = VITAL.unpack_from(self.body)
        except struct.error:
            pass

    def summary(self) -> str:
        t = TYPE_NAME.get(self.type, "?")
        base = ("[%s] f=%-6d lat=%4dms mode=%d " %
                (t, self.frame_id or 0, self.latency_ms or 0, self.mode or 0))
        if self.type == TYPE_STATUS:
            return base + "luma=%d clip=%d.%d%% ae=%d ag=%d fps=%d.%d drop=%d status=0x%02X" % (
                self.luma_mean, self.clip_permille // 10, self.clip_permille % 10,
                self.ae, self.ag, self.fps_x10 // 10, self.fps_x10 % 10,
                self.drop_cnt, self.status_bits)
        if self.type == TYPE_DETECT:
            return base + "class=%d n=%d box=(%d,%d)-(%d,%d) fill=%d.%d%% area=%d" % (
                self.class_id, self.count, self.x0, self.y0, self.x1, self.y1,
                self.fill_permille // 10, self.fill_permille % 10, self.area_px)
        if self.type == TYPE_MOTION:
            return base + "motion=%d box=(%d,%d)-(%d,%d) tiles=%d" % (
                self.motion_count, self.x0, self.y0, self.x1, self.y1, self.tiles_hit)
        if self.type == TYPE_VITAL:
            hr = self.hr_x10 / 10.0
            return base + "HR=%.1f BPM roi_mean=%d ac=%d q=%d roi=(%d,%d)-(%d,%d)" % (
                hr, self.roi_mean, self.roi_ac, self.quality,
                self.rx0, self.ry0, self.rx1, self.ry1)
        return base


def parse_payload(payload: bytes):
    """返回 (Telemetry, 图片块 or None)。"""
    if len(payload) < TLM_HEADER.size:
        return None, None
    (magic, ver, typ, fid, ts, lat, mode, flags, blen) = TLM_HEADER.unpack_from(payload)
    if magic != MAGIC:
        return None, None
    body = payload[TLM_HEADER.size: TLM_HEADER.size + blen]
    t = Telemetry(magic=magic, version=ver, type=typ, frame_id=fid, ts_ms=ts,
                  latency_ms=lat, mode=mode, flags=flags, body_len=blen,
                  body=body, recv_t=time.time())
    t.decode_body()

    chunk = None
    if typ == TYPE_IMAGE and len(body) >= IMGHDR.size:
        (fseq, cidx, ctot, w, h, fmt, fl, _rsv) = IMGHDR.unpack_from(body)
        chunk = dict(frame_seq=fseq, idx=cidx, total=ctot,
                     w=w, h=h, fmt=fmt, flags=fl,
                     data=body[IMGHDR.size:])
    return t, chunk


class UartFramer:
    """从字节流里切出 UART 物理帧：AA 55 | LEN(2) | PAYLOAD | CRC16(2)"""

    def __init__(self):
        self.buf = bytearray()
        self.bad_crc = 0
        self.ok = 0

    def feed(self, data: bytes):
        self.buf.extend(data)
        out = []
        while True:
            i = self.buf.find(UART_SYNC)
            if i < 0:
                # 保留最后一个字节，可能是半个 sync
                if len(self.buf) > 1:
                    del self.buf[:-1]
                break
            if i > 0:
                del self.buf[:i]
            if len(self.buf) < 4:
                break
            ln = self.buf[2] | (self.buf[3] << 8)
            if ln > UART_MAX_PAYLOAD:
                del self.buf[:2]          # 假的 sync，跳过
                continue
            total = 4 + ln + 2
            if len(self.buf) < total:
                break
            payload = bytes(self.buf[4:4 + ln])
            crc_rx = self.buf[4 + ln] | (self.buf[5 + ln] << 8)
            if crc16_ccitt(payload) == crc_rx:
                self.ok += 1
                out.append(payload)
            else:
                self.bad_crc += 1
            del self.buf[:total]
        return out


# ---------------------------------------------------------------- 接收端

class Receiver:
    def __init__(self, outdir="out", verbose=True, plot=False):
        self.outdir = outdir
        os.makedirs(outdir, exist_ok=True)
        self.verbose = verbose
        self.plot = plot
        self.csv_path = os.path.join(outdir, "telemetry.csv")
        self.csv_f = open(self.csv_path, "w", newline="", encoding="utf-8")
        self.csv_w = csv.writer(self.csv_f)
        self.csv_w.writerow(["pc_time", "type", "frame_id", "ts_ms", "latency_ms",
                             "mode", "flags", "summary"])
        self.n_pkt = 0
        self.n_img = 0
        self.imgs = {}          # frame_seq -> {total, chunks:{}}
        self.t0 = time.time()

    def close(self):
        try:
            self.csv_f.close()
        except Exception:
            pass

    def handle(self, payload: bytes):
        t, chunk = parse_payload(payload)
        if t is None:
            return
        self.n_pkt += 1
        s = t.summary()
        self.csv_w.writerow([time.strftime("%H:%M:%S"), TYPE_NAME.get(t.type, "?"),
                             t.frame_id, t.ts_ms, t.latency_ms, t.mode, t.flags, s])
        if self.n_pkt % 20 == 1:
            self.csv_f.flush()

        if self.verbose:
            print(s, flush=True)

        if chunk is not None:
            self._handle_image(chunk)

    def _handle_image(self, c):
        seq = c["frame_seq"]
        st = self.imgs.setdefault(seq, {"total": c["total"], "chunks": {},
                                        "w": c["w"], "h": c["h"], "fmt": c["fmt"],
                                        "first": time.time()})
        st["chunks"][c["idx"]] = c["data"]
        got, tot = len(st["chunks"]), st["total"]
        if self.verbose and (got == 1 or got == tot or got % 50 == 0):
            print("  IMAGE seq=%d  %d/%d chunks  %dx%d %s" %
                  (seq, got, tot, st["w"], st["h"], IMG_FMT_NAME.get(st["fmt"], "?")), flush=True)
        if got >= tot:
            path = os.path.join(self.outdir, "img_%05d_%dx%d_%s.raw" %
                                (seq, st["w"], st["h"], IMG_FMT_NAME.get(st["fmt"], "?")))
            with open(path, "wb") as f:
                for i in range(tot):
                    f.write(st["chunks"].get(i, b""))
            self.n_img += 1
            dt = time.time() - st["first"]
            print("  => 图片完成 %s  (%d B, %.2f s, %.1f KB/s)" %
                  (os.path.basename(path), os.path.getsize(path), dt,
                   os.path.getsize(path) / 1024.0 / max(dt, 1e-6)), flush=True)
            del self.imgs[seq]

    def stats(self):
        dt = time.time() - self.t0
        return ("收到 %d 包 / %d 图 / %.1f s  → %.1f 包/s"
                % (self.n_pkt, self.n_img, dt, self.n_pkt / max(dt, 1e-6)))


# ---------------------------------------------------------------- 自测

def make_status(fid, t):
    body = STATUS.pack(120 + (fid % 30), 12, 1200 + fid % 100, 80, 600, 0x1F, 0, 0)
    return pack_tlm(TYPE_STATUS, fid, t, 12 + fid % 5, 5, 0, body)


def make_vital(fid, t):
    import math
    hr = 72.0 + 3.0 * math.sin(fid / 20.0)          # 模拟心率缓慢变化
    body = VITAL.pack(int(hr * 10), 130 + int(6 * math.sin(fid / 6.0)),
                      int(20 + 15 * math.sin(fid / 5.0)), 3, 0, 100, 80, 300, 260)
    return pack_tlm(TYPE_VITAL, fid, t, 15, 5, 0, body)


def make_image(seq, w=160, h=90, fmt=0, chunk=1000):
    """生成一张渐变测试图并分片。"""
    if fmt == 0:      # RGB565
        px = bytearray()
        for y in range(h):
            for x in range(w):
                r = (x * 31) // w
                g = (y * 63) // h
                b = ((x + y) * 31) // (w + h)
                v = (r << 11) | (g << 5) | b
                px += struct.pack("<H", v)
        fmt_id = 0
    elif fmt == 2:    # GRAY8
        px = bytearray(((x * 255) // w for y in range(h) for x in range(w)))
        fmt_id = 2
    else:             # RGB888
        px = bytearray()
        for y in range(h):
            for x in range(w):
                px += bytes(((x * 255) // w, (y * 255) // h, 128))
        fmt_id = 1
    total = (len(px) + chunk - 1) // chunk
    pkts = []
    for i in range(total):
        d = px[i * chunk:(i + 1) * chunk]
        hdr = IMGHDR.pack(seq, i, total, w, h, fmt_id, 0, 0)
        pkts.append(pack_tlm(TYPE_IMAGE, seq, 0, 3, 5, 0, hdr + bytes(d)))
    return pkts


def pack_tlm(typ, fid, ts, lat, mode, flags, body):
    head = TLM_HEADER.pack(MAGIC, VERSION, typ, fid & 0xFFFF,
                           ts & 0xFFFFFFFF,          # FPGA 侧 ms 计数器是 32bit，回绕
                           lat & 0xFFFF, mode & 0xFF, flags & 0xFF, len(body))
    return head + body


def wrap_uart(payload):
    return UART_SYNC + struct.pack("<H", len(payload)) + payload + \
           struct.pack("<H", crc16_ccitt(payload))


def selftest(outdir, n_frames=120, img_every=40):
    print("=== 自测：生成模拟数据流并解析（不需要 FPGA）===")
    rx = Receiver(outdir=outdir)
    t = 0                     # 模拟 FPGA 侧的 ms 计数器（从 0 开始，32bit 回绕）
    # 1) 遥测：先验证 UART 组帧 + CRC + 解析
    framer = UartFramer()
    raw = b""
    for fid in range(n_frames):
        raw += wrap_uart(make_status(fid, t + fid * 16))
        raw += wrap_uart(make_vital(fid, t + fid * 16))
    print("UART 流 %d 字节" % len(raw))
    # 故意插入垃圾字节，验证重同步
    raw_bad = b"\x11\x22\xAA\x55\xFF\xFF" + raw[10:] + b"\x00" * 7 + raw
    payloads = framer.feed(raw_bad)
    print("注入垃圾后解析出 %d 个包, CRC ok=%d bad=%d（bad 应为 0）" %
          (len(payloads), framer.ok, framer.bad_crc))
    for pl in payloads:
        rx.handle(pl)

    # 2) 图片分片与重组
    print("\n--- 图片分片与重组 ---")
    for k in range(3):
        seq = k + 1
        for pl in make_image(seq, 160, 90, fmt=0, chunk=1000):
            rx.handle(pl)

    print("\n" + rx.stats())
    print("CSV : %s (%d 行)" % (rx.csv_path,
                               sum(1 for _ in open(rx.csv_path, encoding="utf-8")) - 1))
    print("图片: %s" % ", ".join(f for f in sorted(os.listdir(outdir))
                                if f.startswith("img_")))
    rx.close()
    return 0


# ---------------------------------------------------------------- 主程序

def main():
    ap = argparse.ArgumentParser(description="医学数据/抓拍图片上传通道 PC 端")
    ap.add_argument("--selftest", action="store_true", help="不需要 FPGA，自测协议")
    ap.add_argument("--udp", action="store_true", help="监听 UDP")
    ap.add_argument("--serial", metavar="PORT", help="监听串口，如 COM3")
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=5000)
    ap.add_argument("--out", default="out", help="输出目录")
    ap.add_argument("--frames", type=int, default=0, help="自测帧数（0=默认）")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    if a.selftest or (not a.udp and not a.serial):
        return selftest(a.out, n_frames=a.frames or 120)

    rx = Receiver(outdir=a.out, verbose=not a.quiet)

    if a.udp:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((a.bind, a.port))
        print("监听 UDP %s:%d   (Ctrl-C 退出)" % (a.bind, a.port), flush=True)
        try:
            while True:
                data, addr = s.recvfrom(4096)
                if rx.n_pkt == 0:
                    print("首个包来自 %s:%d" % addr, flush=True)
                rx.handle(data)
        except KeyboardInterrupt:
            pass
        finally:
            rx.close()
        return 0

    if a.serial:
        try:
            import serial                       # pyserial，可选
        except ImportError:
            print("需要 pyserial：python -m pip install pyserial", file=sys.stderr)
            return 2
        sp = serial.Serial(a.serial, a.baud, timeout=0.2)
        framer = UartFramer()
        print("监听串口 %s @ %d   (Ctrl-C 退出)" % (a.serial, a.baud), flush=True)
        try:
            while True:
                d = sp.read(4096)
                if d:
                    for pl in framer.feed(d):
                        rx.handle(pl)
        except KeyboardInterrupt:
            pass
        finally:
            rx.close()
            sp.close()
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

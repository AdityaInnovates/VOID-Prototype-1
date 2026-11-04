#!/usr/bin/env python3
"""Gate 0 (part 1): SSD random-read bandwidth for expert-sized reads on this Mac.
Run:  python3 Eval/streaming/gate0_ssd.py
Writes a 3 GB scratch file to $TMPDIR, reads it back with F_NOCACHE (no page cache)
at several read sizes and queue depths, prints GB/s, then deletes the file.
Pass: >= 2.0 GB/s at 4-6 MB reads, queue depth 8.  Keep the Mac on AC, close Chrome."""
import os, sys, time, random, fcntl, tempfile, threading
SIZE_GB = 3
F_NOCACHE = 48  # macOS
path = os.path.join(tempfile.gettempdir(), "void_gate0.bin")
chunk = os.urandom(8 * 1024 * 1024)
print(f"writing {SIZE_GB} GB scratch file at {path} ...")
with open(path, "wb") as f:
    for _ in range(SIZE_GB * 128):
        f.write(chunk)
    f.flush(); os.fsync(f.fileno())
total = os.path.getsize(path)
fd = os.open(path, os.O_RDONLY)
fcntl.fcntl(fd, F_NOCACHE, 1)
ALIGN = 16384

def bench(read_mb, qd, seconds=6):
    n = int(read_mb * 1024 * 1024) // ALIGN * ALIGN
    slots = total // n
    done = [0]; lock = threading.Lock(); stop = time.time() + seconds
    def worker():
        rnd = random.Random()
        while time.time() < stop:
            off = rnd.randrange(slots) * n
            b = os.pread(fd, n, off)
            with lock: done[0] += len(b)
    ts = [threading.Thread(target=worker) for _ in range(qd)]
    t0 = time.time()
    [t.start() for t in ts]; [t.join() for t in ts]
    return done[0] / (time.time() - t0) / 1e9

print(f"{'read MB':>8} {'QD':>4} {'GB/s':>7}")
for mb in (1.5, 4, 6.2, 16):
    for qd in (1, 4, 8, 16):
        print(f"{mb:>8} {qd:>4} {bench(mb, qd):>7.2f}", flush=True)
os.close(fd); os.remove(path)
print("done; scratch file removed. Send me this output.")

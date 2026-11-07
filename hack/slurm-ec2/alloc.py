"""B2's workload: touch 2 GiB in 64 MiB pieces, so a 512 MiB job limit is crossed by real pages."""
import sys

held = []
for i in range(32):
    piece = bytearray(64 << 20)
    for j in range(0, len(piece), 4096):
        piece[j] = 1
    held.append(piece)
    print(f"allocated {(i + 1) * 64} MiB", flush=True)
print("survived", flush=True)
sys.exit(0)

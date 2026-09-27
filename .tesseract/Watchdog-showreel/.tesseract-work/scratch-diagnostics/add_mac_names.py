"""Add Mac-platform duplicates of a TTF's Windows name records.

Why: tsrct 0.2.0 resolves packaged faces by family/style but (observed) only reads
Mac/Unicode-platform `name` records. Fonts that ship Windows-platform records only
(Space Grotesk, JetBrains Mono upstream builds) import fine but render as
`missing_fonts`. Arial, which carries Mac records, resolves.

The derivative changes nothing but the `name` table: records 1, 2, 4, 6 are copied
from platform 3 (Windows, Unicode BMP, en-US) to platform 1 (Mac, Roman, English).
Both source fonts are OFL-1.1 without Reserved Font Names, so the modified copy may
keep its name. Output keeps the upstream file untouched.

Usage: python add_mac_names.py in.ttf out.ttf
"""
import struct
import sys


def checksum(data):
    data = data + b"\0" * (-len(data) % 4)
    return sum(struct.unpack(f">{len(data) // 4}I", data)) & 0xFFFFFFFF


def main(src, dst):
    font = bytearray(open(src, "rb").read())
    num_tables = struct.unpack(">H", font[4:6])[0]
    dir_entries = {}
    for i in range(num_tables):
        off = 12 + 16 * i
        tag, cs, t_off, t_len = struct.unpack(">4sIII", font[off : off + 16])
        dir_entries[tag] = (off, t_off, t_len)

    _, n_off, n_len = dir_entries[b"name"]
    name = bytes(font[n_off : n_off + n_len])
    fmt, count, str_off = struct.unpack(">HHH", name[:6])
    records = []
    for i in range(count):
        rec = struct.unpack(">6H", name[6 + 12 * i : 18 + 12 * i])
        pid, eid, lid, nid, length, offset = rec
        raw = name[str_off + offset : str_off + offset + length]
        records.append((pid, eid, lid, nid, raw))

    have_mac = {(r[3]) for r in records if r[0] == 1}
    added = []
    for pid, eid, lid, nid, raw in records:
        if pid == 3 and eid == 1 and lid == 0x0409 and nid in (1, 2, 4, 6) and nid not in have_mac:
            text = raw.decode("utf-16-be")
            added.append((1, 0, 0, nid, text.encode("mac_roman")))
            if ADD_UNICODE:
                added.append((0, 3, 0, nid, raw))
    if not added:
        raise SystemExit(f"{src}: nothing to add (already has Mac records or no en-US Windows records)")
    records = sorted(records + added, key=lambda r: (r[0], r[1], r[2], r[3]))

    strings = b""
    recs = b""
    for pid, eid, lid, nid, raw in records:
        recs += struct.pack(">6H", pid, eid, lid, nid, len(raw), len(strings))
        strings += raw
    new_name = struct.pack(">HHH", 0, len(records), 6 + 12 * len(records)) + recs + strings

    # Append the new table at the (4-byte aligned) end and repoint the directory.
    font += b"\0" * (-len(font) % 4)
    new_off = len(font)
    font += new_name
    font += b"\0" * (-len(font) % 4)
    d_off = dir_entries[b"name"][0]
    struct.pack_into(">III", font, d_off + 4, checksum(new_name), new_off, len(new_name))

    # Recompute head.checkSumAdjustment over the whole file.
    _, h_off, _ = dir_entries[b"head"]
    struct.pack_into(">I", font, h_off + 8, 0)
    struct.pack_into(">I", font, h_off + 8, (0xB1B0AFBA - checksum(bytes(font))) & 0xFFFFFFFF)
    open(dst, "wb").write(font)
    print(f"{dst}: added Mac name records {[r[3] for r in added]}")


ADD_UNICODE = "--unicode" in sys.argv

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    main(args[0], args[1])

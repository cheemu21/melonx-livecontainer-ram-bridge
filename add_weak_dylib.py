#!/usr/bin/env python3
"""Appends an LC_LOAD_WEAK_DYLIB load command to a thin arm64 Mach-O.

Weak means the binary still runs if the dylib can't be found. The command goes last so the
ordinals of the binary's existing libraries don't change. The binary's code signature is invalid
afterwards, so it has to be signed again.
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
LC_SEGMENT_64 = 0x19
LC_LOAD_WEAK_DYLIB = 0x80000018
DYLIB_COMMANDS = {0x0C, 0x80000018, 0x8000001F, 0x80000023}  # load, weak, reexport, upward
HEADER_SIZE = 32


def main(path, dylib_path):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    magic, cputype, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", data, 0)

    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64:
        sys.exit(f"{path}: not a thin arm64 Mach-O")

    first_content = len(data)
    offset = HEADER_SIZE

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, offset)

        if cmd in DYLIB_COMMANDS:
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            name = bytes(data[offset + name_offset:offset + cmdsize]).split(b"\0", 1)[0].decode()

            if name == dylib_path:
                sys.exit(f"{path}: already links {dylib_path}")

        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, offset + 64)[0]

            for i in range(nsects):
                section = offset + 72 + i * 80
                section_type = struct.unpack_from("<I", data, section + 64)[0] & 0xFF
                file_offset = struct.unpack_from("<I", data, section + 48)[0]

                # Zero-fill sections take up no room in the file.
                if file_offset and section_type not in (0x01, 0x0C, 0x12):
                    first_content = min(first_content, file_offset)

        offset += cmdsize

    name = dylib_path.encode() + b"\0"
    cmdsize = (24 + len(name) + 7) & ~7
    command = struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000)
    command += name.ljust(cmdsize - 24, b"\0")

    end = HEADER_SIZE + sizeofcmds
    room = first_content - end

    if room < cmdsize:
        sys.exit(f"{path}: only {room} bytes free after the load commands, need {cmdsize}")

    if any(data[end:end + cmdsize]):
        sys.exit(f"{path}: the padding after the load commands isn't empty")

    data[end:end + cmdsize] = command
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)

    with open(path, "wb") as f:
        f.write(data)

    print(f"Added {dylib_path} to {path} ({room - cmdsize} bytes of padding left)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: add_weak_dylib.py <binary> <dylib path>")

    main(sys.argv[1], sys.argv[2])

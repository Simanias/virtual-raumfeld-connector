#!/usr/bin/env python3
# Builds the renderer's private, patched copies of two firmware libraries, so that the renderer runs as
# a real Connector 2 (hardware id 9 — needed for the EQ, line-in and the other Connector 2 settings in the
# app) while it still plays to an ordinary ALSA sound card:
#
#   libraumfeld-1.0.so     raumfeld_is_virtualised_environment() -> false
#                          (otherwise the renderer plays to a network "virtual sound card")
#   libraumfeldcpp-1.0.so  Hardware::getDriftCompensatorType()   -> 2 = software time-stretching
#                          (a Connector 2 otherwise needs the "Drift compensator" mixer control of its codec)
#                          capture device "hw:0,0" -> "vc_cap" (defined in asound.conf by vc-up.sh)
#
# Only the renderer loads these copies (LD_LIBRARY_PATH in its wrapper); hardwared and the other firmware
# processes keep using the originals. Functions are located by symbol name, not by fixed offsets.
#
#   vc-renderer-libs.py <rootfs> <output dir>
import os, struct, sys

def elf_symbols(d):
    """{name: value} of the dynamic symbols of a 32-bit little-endian ELF."""
    if d[:4] != b"\x7fELF" or d[4] != 1 or d[5] != 1:
        raise ValueError("not a 32-bit little-endian ELF")
    shoff, = struct.unpack_from("<I", d, 0x20)
    shentsize, shnum = struct.unpack_from("<HH", d, 0x2E)
    secs = [struct.unpack_from("<IIIIIIIIII", d, shoff + i * shentsize) for i in range(shnum)]
    syms = {}
    for s in secs:
        if s[1] != 11:                                   # SHT_DYNSYM
            continue
        strtab = secs[s[6]]                              # sh_link -> .dynstr
        for off in range(s[4], s[4] + s[5], 16):
            st_name, st_value = struct.unpack_from("<II", d, off)
            end = d.index(b"\0", strtab[4] + st_name)
            syms[d[strtab[4] + st_name:end].decode()] = st_value
    return syms

def file_offset(d, vaddr):
    phoff, = struct.unpack_from("<I", d, 0x1C)
    phentsize, phnum = struct.unpack_from("<HH", d, 0x2A)
    for i in range(phnum):
        p_type, p_offset, p_vaddr, _, p_filesz = struct.unpack_from("<IIIII", d, phoff + i * phentsize)
        if p_type == 1 and p_vaddr <= vaddr < p_vaddr + p_filesz:   # PT_LOAD
            return vaddr - p_vaddr + p_offset
    raise ValueError("address 0x%x not in a loaded segment" % vaddr)

def patch_return(d, name, value):
    """Let function <name> immediately return <value> (ARM or Thumb code)."""
    addr = elf_symbols(d)[name]
    if addr & 1:                                         # Thumb: movs r0,#value ; bx lr
        code = struct.pack("<HH", 0x2000 | value, 0x4770)
    else:                                                # ARM:   mov r0,#value  ; bx lr
        code = struct.pack("<II", 0xE3A00000 | value, 0xE12FFF1E)
    off = file_offset(d, addr & ~1)
    d[off:off + len(code)] = code

def build(src, dst, patch):
    d = bytearray(open(src, "rb").read())
    patch(d)
    tmp = dst + ".tmp"
    with open(tmp, "wb") as f:
        f.write(d)
    os.chmod(tmp, 0o755)
    os.replace(tmp, dst)

def patch_cpp(d):
    patch_return(d, "_ZN6Teufel5Tools8Hardware23getDriftCompensatorTypeEv", 2)
    old, new = b"\0hw:0,0\0", b"\0vc_cap\0"            # same length, so nothing else moves
    if old not in d:
        raise ValueError("capture device name not found")
    d[:] = d.replace(old, new)

def main():
    root, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    lib = os.path.join(root, "usr/lib")
    build(os.path.join(lib, "libraumfeld-1.0.so"), os.path.join(out, "libraumfeld-1.0.so"),
          lambda d: patch_return(d, "raumfeld_is_virtualised_environment", 0))
    build(os.path.join(lib, "libraumfeldcpp-1.0.so"), os.path.join(out, "libraumfeldcpp-1.0.so"), patch_cpp)
    print("  renderer libraries prepared in", out)

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("  !! could not prepare the renderer libraries:", e)
        sys.exit(1)

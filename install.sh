#!/usr/bin/env bash
# install.sh — Install codex-yolo from source
# Usage: curl -fsSL https://<url>/install.sh | bash && source ~/.bashrc
set -euo pipefail

REPO="https://github.com/codex-yolo/codex-yolo.git"
INSTALL_DIR="${CODEX_YOLO_HOME:-$HOME/.codex-yolo}"
BIN_DIR="$HOME/.local/bin"

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BOLD='\033[1m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

info()  { printf "${GREEN}==>${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}WARNING:${RESET} %s\n" "$*"; }
error() { printf "${RED}ERROR:${RESET} %s\n" "$*" >&2; exit 1; }

# Detect Termux (Android) — no sudo, uses pkg
IS_TERMUX=0
if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d /data/data/com.termux ]]; then
    IS_TERMUX=1
fi

# Install a package using the appropriate package manager
# Usage: install_pkg <package_name>
install_pkg() {
    local pkg="$1"
    local os="$(uname -s)"
    if [[ "$os" == Darwin* ]]; then
        if command -v brew &>/dev/null; then
            brew install "$pkg"
        else
            error "$pkg is required. Install Homebrew (https://brew.sh) then run: brew install $pkg"
        fi
    elif [[ "$os" == Linux* ]]; then
        if [[ "$IS_TERMUX" -eq 1 ]]; then
            pkg install -y "$pkg"
        elif command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y "$pkg"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y "$pkg"
        elif command -v yum &>/dev/null; then
            sudo yum install -y "$pkg"
        elif command -v pacman &>/dev/null; then
            sudo pacman -S --noconfirm "$pkg"
        elif command -v apk &>/dev/null; then
            sudo apk add "$pkg"
        else
            error "$pkg is required but no supported package manager found. Install $pkg manually."
        fi
    else
        error "$pkg is required. Install it manually for your platform."
    fi
}

# -------------------------------------------------------------------
# Pre-flight checks
# -------------------------------------------------------------------
if ! command -v git &>/dev/null; then
    info "git is not installed — attempting to install"
    install_pkg git
    command -v git &>/dev/null || error "git installation failed — install it manually and re-run"
    info "git installed successfully"
fi

# -------------------------------------------------------------------
# Detect OS
# -------------------------------------------------------------------
OS="$(uname -s)"
IS_WSL=0
case "$OS" in
    Linux*)
        if [[ "$IS_TERMUX" -eq 1 ]]; then
            info "Detected platform: Termux (Android)"
        elif grep -qi microsoft /proc/version 2>/dev/null; then
            info "Detected platform: WSL (Windows Subsystem for Linux)"
            IS_WSL=1
        else
            info "Detected platform: Linux"
        fi
        ;;
    Darwin*)
        info "Detected platform: macOS"
        ;;
    *)
        warn "Unrecognized platform: $OS — proceeding anyway"
        ;;
esac

# -------------------------------------------------------------------
# Install tmux if missing
# -------------------------------------------------------------------
if ! command -v tmux &>/dev/null; then
    info "tmux is not installed — attempting to install"
    install_pkg tmux
    command -v tmux &>/dev/null || error "tmux installation failed — install it manually and re-run"
    info "tmux installed successfully"
fi

# -------------------------------------------------------------------
# Install Codex CLI if missing
# -------------------------------------------------------------------
if ! command -v codex &>/dev/null; then
    info "Codex CLI is not installed — installing via npm"
    if [[ "$IS_TERMUX" -eq 1 ]]; then
        if ! command -v npm &>/dev/null; then
            info "npm is not installed — installing via pkg"
            pkg install -y nodejs
        fi
        # Codex CLI ships native binaries as npm-aliased optional deps, e.g.
        #   "@openai/codex-linux-arm64": "npm:@openai/codex@0.112.0-linux-arm64"
        # Two problems on Termux:
        #   1. npm skips the optional dep because os is "android" not "linux"
        #   2. The musl-static binary is ET_EXEC (fixed-address), which
        #      Android's linker rejects (requires ET_DYN / PIE)
        # Fix: install the platform tarball manually, then patch the binary's
        # ELF e_type from ET_EXEC (2) to ET_DYN (3). musl/Rust static binaries
        # are position-independent so this one-byte patch is safe.
        npm install -g @openai/codex || error "Failed to install Codex CLI"
        NPM_GLOBAL="$(npm root -g)"
        CODEX_VER="$(node -e "import('$NPM_GLOBAL/@openai/codex/package.json',{with:{type:'json'}}).then(m=>console.log(m.default.version))")"
        CODEX_CPU="$(uname -m)"
        case "$CODEX_CPU" in
            aarch64|arm64) CODEX_CPU="arm64" ;;
            x86_64)        CODEX_CPU="x64" ;;
        esac
        PLATFORM_DIR="$NPM_GLOBAL/@openai/codex-linux-${CODEX_CPU}"
        if [[ ! -d "$PLATFORM_DIR" ]]; then
            info "Installing platform binary (codex@${CODEX_VER}-linux-${CODEX_CPU})"
            mkdir -p "$PLATFORM_DIR"
            curl -fsSL "https://registry.npmjs.org/@openai/codex/-/codex-${CODEX_VER}-linux-${CODEX_CPU}.tgz" \
                | tar xz -C "$PLATFORM_DIR" --strip-components=1 \
                || error "Failed to download platform binary"
            info "Platform binary installed successfully"
        fi
    else
        if ! command -v npm &>/dev/null; then
            error "npm is required to install Codex CLI. Install Node.js/npm first: https://nodejs.org"
        fi
        npm install -g @openai/codex || error "Failed to install Codex CLI"
    fi
    command -v codex &>/dev/null || warn "Codex CLI installed but not found in PATH — you may need to restart your shell"
fi

# -------------------------------------------------------------------
# Termux: patch codex.real with synthetic RELA relocations so
# linker64 can load it correctly.  Runs unconditionally so it also
# re-applies after updates.
#
# Why linker64?
# termux-exec (LD_PRELOAD) rewrites every execve(2) as
#   execve("/system/bin/linker64", [argv0, binary, ...args])
# The kernel sees the trusted system linker being launched; linker64
# then mmaps the target binary.  Bypassing termux-exec (OPTOUT env
# var, two-hop trick, etc.) makes the kernel's W^X/SELinux policy
# block the execve — the only path to execution is through linker64.
#
# What linker64 requires
# 1. e_type == ET_DYN                  → patch byte at offset 16
# 2. PT_DYNAMIC program-header entry  → repurpose PT_GNU_STACK slot
# 3. .dynamic section readable in a   → extend last PT_LOAD to cover
#    loaded PT_LOAD segment              our appended data
#
# Why RELA relocations are needed
# linker64 applies ASLR: it loads the binary at   base + p_vaddr.
# The binary's .data.rel.ro, .got, and .init_array contain absolute
# virtual addresses (vtable function pointers etc.) resolved at static
# link time.  Without relocation records those addresses are wrong by
# exactly `base`.
#
# Fix: synthesise R_AARCH64_RELATIVE (0x403) RELA entries for every
# 8-byte slot in those sections whose value falls within the binary's
# own virtual-address range [min_vaddr, max_vaddr).  linker64 applies
#   *(base + r_offset) = base + r_addend
# for each entry, restoring all absolute pointers before it calls
# the entry point.  Values outside that range (size, align, zero) are
# left untouched — they need no adjustment.
# -------------------------------------------------------------------
if [[ "$IS_TERMUX" -eq 1 ]] && command -v codex &>/dev/null; then
    NPM_GLOBAL="$(npm root -g 2>/dev/null || true)"
    if [[ -n "$NPM_GLOBAL" ]]; then
        NATIVE_BIN="$(find "$NPM_GLOBAL" -path "*/codex-linux-*/vendor/*/codex/codex" ! -name "*.real" -type f 2>/dev/null | head -1)"
        if [[ -n "$NATIVE_BIN" ]]; then
            NATIVE_REAL="${NATIVE_BIN}.real"
            if [[ ! -f "$NATIVE_REAL" ]]; then
                mv "$NATIVE_BIN" "$NATIVE_REAL"
            fi
            chmod +x "$NATIVE_REAL"

            # Patch codex.real: ET_DYN + PT_PHDR + PT_DYNAMIC + SHT_DYNAMIC + RELA.
            python3 - "$NATIVE_REAL" << 'PATCH_EOF'
import struct, sys

def patch(path):
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    lt = '<'
    if data[:4] != b'\x7fELF' or data[4] != 2:
        print("Not 64-bit ELF, skipping"); return

    # 1. Ensure ET_DYN
    e_type = struct.unpack_from(lt+'H', data, 16)[0]
    if e_type == 2:
        struct.pack_into(lt+'H', data, 16, 3); print("ET_EXEC -> ET_DYN")
    elif e_type != 3:
        print(f"Unexpected e_type {e_type}"); return

    e_phoff     = struct.unpack_from(lt+'Q', data, 32)[0]
    e_shoff     = struct.unpack_from(lt+'Q', data, 40)[0]
    e_phentsize = struct.unpack_from(lt+'H', data, 54)[0]
    e_phnum     = struct.unpack_from(lt+'H', data, 56)[0]
    e_shentsize = struct.unpack_from(lt+'H', data, 58)[0]
    e_shnum     = struct.unpack_from(lt+'H', data, 60)[0]
    e_shstrndx  = struct.unpack_from(lt+'H', data, 62)[0]

    # 2. Parse program headers
    phdrs = []
    for i in range(e_phnum):
        o = e_phoff + i*e_phentsize
        pt, pf = struct.unpack_from(lt+'II', data, o)
        po, pv, pp, pfs, pms, pa = struct.unpack_from(lt+'QQQQQQ', data, o+8)
        phdrs.append(dict(type=pt,flags=pf,offset=po,vaddr=pv,paddr=pp,
                          filesz=pfs,memsz=pms,align=pa,idx=i))

    # 3. Parse section headers + string table
    ss   = e_shstrndx * e_shentsize
    sfof = struct.unpack_from(lt+'Q', data, e_shoff+ss+24)[0]
    sfsz = struct.unpack_from(lt+'Q', data, e_shoff+ss+32)[0]
    strt = bytes(data[sfof:sfof+sfsz])
    shdrs = []
    for i in range(e_shnum):
        o  = e_shoff + i*e_shentsize
        ni = struct.unpack_from(lt+'I', data, o)[0]
        st = struct.unpack_from(lt+'I', data, o+4)[0]
        av = struct.unpack_from(lt+'Q', data, o+16)[0]
        fo = struct.unpack_from(lt+'Q', data, o+24)[0]
        sz = struct.unpack_from(lt+'Q', data, o+32)[0]
        try: nm = strt[ni:strt.index(b'\x00',ni)].decode()
        except: nm = ''
        shdrs.append(dict(idx=i,name=nm,name_off=ni,type=st,addr=av,foff=fo,size=sz))
    secs = {sh['name']: sh for sh in shdrs if sh['name']}

    loads = [p for p in phdrs if p['type']==1]
    last  = max(loads, key=lambda p: p['offset']+p['filesz'])
    first = min(loads, key=lambda p: p['offset'])

    # Current patch state
    pt_dyn  = next((p for p in phdrs if p['type'] == 2), None)   # PT_DYNAMIC
    pt_phdr = next((p for p in phdrs if p['type'] == 6), None)   # PT_PHDR
    sht_dyn = next((sh for sh in shdrs if sh['type'] == 6), None) # SHT_DYNAMIC
    changed = False

    # ── Step A: Ensure PT_DYNAMIC + RELA ──────────────────────────────────────
    if pt_dyn is None:
        min_v = min(p['vaddr'] for p in loads)
        max_v = max(p['vaddr']+p['memsz'] for p in loads)
        print(f"Last PT_LOAD idx={last['idx']} ptr_range=[0x{min_v:x},0x{max_v:x})")

        # Free slot for PT_DYNAMIC: prefer PT_GNU_STACK, fallback to other GNU_*
        free = -1
        for tgt in [0x6474e551,0x6474e550,0x6474e553,0]:
            for p in phdrs:
                if p['type']==tgt: free=p['idx']; break
            if free!=-1: break
        if free==-1: sys.exit("No free phdr slot for PT_DYNAMIC")
        print(f"Using phdr slot {free} for PT_DYNAMIC")

        # Generate R_AARCH64_RELATIVE (0x403) RELA entries for absolute ptrs
        relas = []
        def scan(name):
            if name not in secs: return
            s = secs[name]; n = 0
            for i in range(0, s['size']-7, 8):
                v = struct.unpack_from(lt+'Q', data, s['foff']+i)[0]
                if min_v <= v < max_v:
                    relas.append((s['addr']+i, 0x403, v)); n += 1
            print(f"  {name}: {n}/{s['size']//8} ptrs")
        print("Scanning sections:")
        for nm in ['.got','.init_array','.fini_array','.data.rel.ro']:
            scan(nm)
        relas.sort(); print(f"Total RELA entries: {len(relas)}")

        # Append RELA + .dynamic at end of file (8-byte aligned)
        a8 = lambda x: (x+7)&~7
        rela_fo = a8(len(data))
        rela_b  = bytearray(struct.pack(lt+'QQq', ro, ri, ra) for ro,ri,ra in relas)
        dyn_fo  = a8(rela_fo + len(rela_b))
        dyn_sz  = 4*16
        new_sz  = dyn_fo + dyn_sz
        f2v = lambda fo: last['vaddr'] + (fo - last['offset'])
        rv  = f2v(rela_fo); dv = f2v(dyn_fo)
        print(f"RELA  foff=0x{rela_fo:x} vaddr=0x{rv:x} size={len(rela_b)}")
        print(f".dyn  foff=0x{dyn_fo:x}  vaddr=0x{dv:x}")

        # .dynamic section: DT_RELA, DT_RELASZ, DT_RELAENT, DT_NULL
        dyn = bytearray()
        for tag,val in [(7,rv),(8,len(rela_b)),(9,24),(0,0)]:
            dyn += struct.pack(lt+'QQ', tag, val)

        # Extend last PT_LOAD to cover appended data
        new_fs = new_sz - last['offset']
        new_ms = new_fs + max(0, last['memsz']-last['filesz'])
        po = e_phoff + last['idx']*e_phentsize
        struct.pack_into(lt+'Q', data, po+32, new_fs)
        struct.pack_into(lt+'Q', data, po+40, new_ms)
        print(f"Extended PT_LOAD[{last['idx']}]: filesz->0x{new_fs:x}")

        # Write PT_DYNAMIC into free slot
        po2 = e_phoff + free*e_phentsize
        struct.pack_into(lt+'I', data, po2,   2)
        struct.pack_into(lt+'I', data, po2+4, 6)
        for off,val in [(8,dyn_fo),(16,dv),(24,dv),(32,dyn_sz),(40,dyn_sz),(48,8)]:
            struct.pack_into(lt+'Q', data, po2+off, val)
        print(f"PT_DYNAMIC at slot {free}, vaddr=0x{dv:x}")

        # Append bytes
        while len(data) < rela_fo: data.append(0)
        data += rela_b
        while len(data) < dyn_fo:  data.append(0)
        data += dyn
        pt_dyn = dict(offset=dyn_fo, vaddr=dv, filesz=dyn_sz)
        changed = True
    else:
        dyn_fo = pt_dyn['offset']
        dv     = pt_dyn['vaddr']
        dyn_sz = pt_dyn['filesz']

    # ── Step B: Ensure PT_PHDR ─────────────────────────────────────────────────
    # linker64 needs PT_PHDR to update AT_PHDR in the aux vector so that
    # the binary's startup code (musl) can find the program header table.
    # Repurpose PT_GNU_RELRO (optional RELRO hardening, not needed for execution).
    if pt_phdr is None:
        phdr_vaddr = first['vaddr'] + (e_phoff - first['offset'])
        phdr_sz    = e_phnum * e_phentsize
        for p in phdrs:
            if p['type'] == 0x6474e552:   # PT_GNU_RELRO
                po3 = e_phoff + p['idx']*e_phentsize
                struct.pack_into(lt+'I', data, po3,   6)   # PT_PHDR
                struct.pack_into(lt+'I', data, po3+4, 4)   # PF_R
                for off,val in [(8,e_phoff),(16,phdr_vaddr),(24,phdr_vaddr),
                                (32,phdr_sz),(40,phdr_sz),(48,8)]:
                    struct.pack_into(lt+'Q', data, po3+off, val)
                print(f"PT_PHDR at slot {p['idx']}, vaddr=0x{phdr_vaddr:x}")
                changed = True
                break
        else:
            print("WARNING: no PT_GNU_RELRO slot available for PT_PHDR")

    # ── Step C: Ensure SHT_DYNAMIC with correct sh_link ───────────────────────
    write_sht = True
    target_sh = None
    if sht_dyn is not None:
        link_idx  = struct.unpack_from(lt+'I', data,
            e_shoff + sht_dyn['idx']*e_shentsize + 40)[0]
        link_type = (struct.unpack_from(lt+'I', data,
            e_shoff + link_idx*e_shentsize + 4)[0]
            if link_idx < e_shnum else 0)
        if link_type == 3:   # already correct SHT_STRTAB
            write_sht = False
        else:
            target_sh = sht_dyn   # fix existing entry in-place
    else:
        # Repurpose .comment (9 bytes = ".dynamic\0" exactly)
        target_sh = next((sh for sh in shdrs if sh['name']=='.comment'), None)

    if write_sht:
        if target_sh is None:
            print("WARNING: no section slot for SHT_DYNAMIC")
        else:
            o = e_shoff + target_sh['idx']*e_shentsize
            if target_sh['name'] == '.comment':
                data[sfof+target_sh['name_off']:sfof+target_sh['name_off']+9] = b'.dynamic\0'
            struct.pack_into(lt+'I', data, o+4,  6)          # SHT_DYNAMIC
            struct.pack_into(lt+'Q', data, o+8,  3)          # SHF_WRITE|SHF_ALLOC
            struct.pack_into(lt+'Q', data, o+16, dv)
            struct.pack_into(lt+'Q', data, o+24, dyn_fo)
            struct.pack_into(lt+'Q', data, o+32, dyn_sz)
            struct.pack_into(lt+'I', data, o+40, e_shstrndx) # sh_link = .shstrtab
            struct.pack_into(lt+'I', data, o+44, 0)
            struct.pack_into(lt+'Q', data, o+48, 8)
            struct.pack_into(lt+'Q', data, o+56, 16)
            print(f"SHT_DYNAMIC at section[{target_sh['idx']}], vaddr=0x{dv:x}")
            changed = True

    if not changed:
        print("Already fully patched, skipping"); return

    with open(path,'wb') as f: f.write(data)
    print(f"Done. {len(data)//1024//1024} MB")

patch(sys.argv[1])
PATCH_EOF

            # Wrapper: direct exec — termux-exec wraps as linker64 codex.real,
            # linker64 reads PT_DYNAMIC, applies RELA, calls entry point.
            cat > "$NATIVE_BIN" << 'NATIVE_WRAP_EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec "$(dirname "$(readlink -f "$0")")/codex.real" "$@"
NATIVE_WRAP_EOF
            chmod +x "$NATIVE_BIN"
            info "Patched native codex binary (ET_DYN + PT_DYNAMIC + RELA)"
        fi

        # Restore the codex bin to invoke node directly.
        CODEX_JS="$NPM_GLOBAL/@openai/codex/bin/codex.js"
        PROOT_WRAPPER="$NPM_GLOBAL/@openai/codex/bin/codex-termux-wrapper.sh"
        if [[ -f "$CODEX_JS" && -f "$PROOT_WRAPPER" ]]; then
            cat > "$PROOT_WRAPPER" << 'NODE_WRAP_EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec node "$(dirname "$(readlink -f "$0")")/codex.js" "$@"
NODE_WRAP_EOF
            chmod +x "$PROOT_WRAPPER"
        fi
    fi
fi

# -------------------------------------------------------------------
# Install / update
# -------------------------------------------------------------------
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing installation in $INSTALL_DIR"
    git -C "$INSTALL_DIR" checkout . 2>/dev/null
    git -C "$INSTALL_DIR" pull --ff-only || error "Failed to update. Resolve manually in $INSTALL_DIR"
else
    if [[ -d "$INSTALL_DIR" ]]; then
        error "$INSTALL_DIR already exists but is not a git repo. Remove it first and re-run."
    fi
    info "Cloning codex-yolo into $INSTALL_DIR"
    git clone "$REPO" "$INSTALL_DIR" || error "Failed to clone repository"
fi

chmod +x "$INSTALL_DIR/codex-yolo"

# -------------------------------------------------------------------
# Symlink into PATH
# -------------------------------------------------------------------
mkdir -p "$BIN_DIR"

ln -sf "$INSTALL_DIR/codex-yolo" "$BIN_DIR/codex-yolo"
info "Linked codex-yolo → $BIN_DIR/codex-yolo"

# -------------------------------------------------------------------
# Ensure ~/.local/bin is in PATH
# -------------------------------------------------------------------
# Detect shell config file
SHELL_NAME="$(basename "${SHELL:-/bin/bash}")"
case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
    fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
    *)    RC_FILE="$HOME/.profile" ;;
esac

PATH_NEEDED=0
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    PATH_NEEDED=1

    EXPORT_LINE='export PATH="$HOME/.local/bin:$PATH"'
    if [[ "$SHELL_NAME" == "fish" ]]; then
        EXPORT_LINE='fish_add_path $HOME/.local/bin'
    fi

    if [[ -f "$RC_FILE" ]] && grep -qF '.local/bin' "$RC_FILE" 2>/dev/null; then
        info "PATH entry already exists in $RC_FILE"
    else
        printf '\n# Added by codex-yolo installer\n%s\n' "$EXPORT_LINE" >> "$RC_FILE"
        info "Added $BIN_DIR to PATH in $RC_FILE"
    fi
fi

# -------------------------------------------------------------------
# Done
# -------------------------------------------------------------------
printf "\n${BOLD}${GREEN}codex-yolo installed successfully!${RESET}\n"

if [[ "$PATH_NEEDED" -eq 1 ]]; then
printf "\n  Run this to start using codex-yolo now:\n\n"
printf "    source %s\n\n" "$RC_FILE"
fi
printf "  Usage:\n"
printf "    cd /path/to/your/project\n"
printf "    codex-yolo \"fix the tests\" \"update docs\"\n\n"

# scripts/gdb/gdb_tape_atoms.gdb
#
# Wrapper for the tape-atom step-debug helpers.
# The 9 user commands are defined here as STUBS (degraded-state messages). 
# The real implementations + the per-atom data tables are emitted by `passes/atoms_source_map.lua` 
# (post-link invocation: `ps1_meta.lua --atoms-source-map --gdb-runtime --elf <elf>`) into `build/gdb_tape_atoms_runtime.gdb`.
# Sourcing that file RE-DEFINES the commands with real implementations.
#
# If `build/gdb_tape_atoms_runtime.gdb` is missing or stale, the stubs remain (E1: no source map).
# The user just needs to re-run `build_psyq.ps1` to regenerate.

# ?? Stub commands (defined here so they're always present, even if the runtime file is missing). The runtime file overrides these if sourced. ??

define tape_atoms
  echo "[gdb_tape_atoms] STUB: runtime file build/gdb_tape_atoms_runtime.gdb not found."
  echo "[gdb_tape_atoms] STUB: run .\\build_psyq.ps1 to regenerate, then re-source this file."
end
document tape_atoms
  List every tape atom symbol in the loaded ELF with its .rodata address and word count.
  STUB state: runtime file not sourced. Run build_psyq.ps1 to regenerate.
end

define break_atom
  echo "[gdb_tape_atoms] STUB: build/gdb_tape_atoms_runtime.gdb not sourced. Run build_psyq.ps1."
end
document break_atom
  Set a breakpoint at the start of tape atom <name>. STUB state.
end

define step_atom
  echo "[gdb_tape_atoms] STUB: build/gdb_tape_atoms_runtime.gdb not sourced. Run build_psyq.ps1."
end
document step_atom
  Resume execution until the next atom boundary. STUB state.
end

define next_atom
  echo "[gdb_tape_atoms] STUB: build/gdb_tape_atoms_runtime.gdb not sourced. Run build_psyq.ps1."
end
document next_atom
  Alias for step_atom. STUB state.
end

define where_in_atom
  echo "[gdb_tape_atoms] STUB: build/gdb_tape_atoms_runtime.gdb not sourced. Run build_psyq.ps1."
end
document where_in_atom
  Report current atom name, .rodata addr, word offset, and source line (if known). STUB state.
end

define stepi_inside_atom
  echo "[gdb_tape_atoms] STUB: build/gdb_tape_atoms_runtime.gdb not sourced. Run build_psyq.ps1."
end
document stepi_inside_atom
  One MIPS-instruction step, then where_in_atom. STUB state.
end

define show_c2
  printf "C2[ 0]   0x%08x\n", $c2_data[0]
  printf "C2[ 7]   0x%08x  [otz]\n", $c2_data[7]
  printf "C2[12]   0x%08x  [sxy0]\n", $c2_data[12]
  printf "C2[13]   0x%08x  [sxy1]\n", $c2_data[13]
  printf "C2[14]   0x%08x  [sxy2]\n", $c2_data[14]
  printf "C2[24]   0x%08x  [mac0]\n", $c2_data[24]
  printf "...\n"
   echo "(STUB state: only 7 representative regs shown. Run build_psyq.ps1 for full dump.)"
end
document show_c2
  Pretty-print all 32 C2 data registers as hex + named alias. STUB state (7 reg subset).
end

define show_c2ctl
  printf "C2CTL[ 0]  0x%08x\n", $c2_control[0]
  printf "...\n"
  echo "(STUB state: only 1 reg shown. Run build_psyq.ps1 for full dump.)"
end
document show_c2ctl
  Pretty-print all 32 C2 control registers. STUB state (1 reg subset).
end

define wave_ctx
  printf "$t4 = R_FaceCursor     0x%08x\n", $t4
  printf "$t5 = R_VertBase       0x%08x\n", $t5
  printf "$t6 = R_OtBase         0x%08x\n", $t6
  printf "$t7 = R_PrimCursor     0x%08x\n", $t7
end
document wave_ctx
  Pretty-print the 4 wave-context GPRs ($t4..$t7). (wave_ctx works in stub state too.)
end


# ?? Source the runtime file (re-defines commands with real impls + data). ??

# Try to source from project-root-relative path first (the typical case).
# If the user is in a different CWD, the source will fail and stubs remain.
# The runtime file path is computed relative to the ELF's source map convention (build/gdb_tape_atoms_runtime.gdb).
echo [gdb_tape_atoms] Wrapper loaded. Sourcing runtime file...
# Suppress the "Redefine command" prompts that would otherwise appear when the runtime file overrides the 9 stub commands defined above.
# The runtime's `define` blocks are intended to overwrite ? there's no ambiguity to confirm.
set confirm off

# Source the runtime file (re-defines commands with real impls + data).
source build/gdb_tape_atoms_runtime.gdb
set confirm on
echo [gdb_tape_atoms] Runtime sourced successfully (9 commands now have real implementations).

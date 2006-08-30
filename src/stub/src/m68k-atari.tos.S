/*
;  m68k-atari.tos.S -- loader & decompressor for the atari/tos format
;
;  This file is part of the UPX executable compressor.
;
;  Copyright (C) 1996-2006 Markus Franz Xaver Johannes Oberhumer
;  Copyright (C) 1996-2006 Laszlo Molnar
;  All Rights Reserved.
;
;  UPX and the UCL library are free software; you can redistribute them
;  and/or modify them under the terms of the GNU General Public License as
;  published by the Free Software Foundation; either version 2 of
;  the License, or (at your option) any later version.
;
;  This program is distributed in the hope that it will be useful,
;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;  GNU General Public License for more details.
;
;  You should have received a copy of the GNU General Public License
;  along with this program; see the file COPYING.
;  If not, write to the Free Software Foundation, Inc.,
;  59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
;
;  Markus F.X.J. Oberhumer              Laszlo Molnar
;  <mfx@users.sourceforge.net>          <ml1050@users.sourceforge.net>
;
*/

.altmacro


/*
;
; see also:
;   freemint/sys/mint/basepage.h
;   freemint/sys/mint/mem.h         (FILEHEAD)
;   freemint/sys/memory.c           (load_region, load_and_reloc)
;   freemint/sys/arch/cpu.S         (cpush)
;

;
; This file is first preprocessed by cpp, then the a68k assembler
; is run and finally the generated object file is translated to a .h file
; by a simple perl script. We also maintain compatiblity with the pasm
; assembler (which must be started in the emulator window).
;
*/

#define macro(name)   .macro name
#define endm          .endm
#define section       .section

/*
; basepage offsets
p_lowtpa        equ     $0      ; .l    pointer to self (bottom of TPA)
p_hitpa         equ     $4      ; .l    pointer to top of TPA + 1
p_tbase         equ     $8      ; .l    base of text segment
p_tlen          equ     $c      ; .l    length of text segment
p_dbase         equ     $10     ; .l    base of data segment
p_dlen          equ     $14     ; .l    length of data segment
p_bbase         equ     $18     ; .l    base of BSS segment
p_blen          equ     $1c     ; .l    length of BSS segment
p_dta           equ     $20     ; .l    pointer to current DTA
p_parent        equ     $24     ; .l    pointer to parent's basepage
p_flags         equ     $28     ; .l    memory usage flags
p_env           equ     $2c     ; .l    pointer to environment string
*/

p_tbase = 8

/*
; long living registers:
;   d4  p_tbase - start of text segment
;   a6  p_bbase - start of decompressed bss segment, this also is the
;                     - end of decompressed text+data
;                     - start of decompressed relocations
;                     - start of dirty bss
;   ASTACK (a7) - final startup code copied below stack
*/


/*************************************************************************
// flush cache macros
**************************************************************************/

/*
; note:
;   GEMDOS/XBIOS trashes d0, d1, d2, a0, a1, a2
;
; long Ssystem(S_FLUSHCACHE, base, length) - inside the kernel this
; is called `cpush(base, length)'.
;   returns: d0.l should be either 0 or -32 (== ENOSYS == EINVFN)
; Available since FreeMiNT 1.15.1 (1999-04-13).
;
; Note that on a 68060 FreeMiNT just uses `cpusha bc' in all cases,
; so we don't bother passing base and length. (info: base would be d4)
*/

macro(MINT_FLUSH_CACHE)
                pea     -1              // length
                clr.l   -(sp)           // base
#if 0
                move.w  #0x016,-(sp)    // S_FLUSHCACHE (22)
                move.w  #0x154,-(sp)    // Ssystem (340)
#else
                move.l  #0x01540016,-(sp)
#endif
                trap    #1              // GEMDOS
                lea     12(sp),sp
        endm


// First try `cpusha bc' (68040/68060). If that fails try temporary changing
// the cache control register (68030).

macro(SUPEXEC_FLUSH_CACHE)
                local   exception, super, fc1, fc2, ret, done

                pea     super(pc)
                move.w  #0x0026,-(sp)   // Supexec (38)
                trap    #14             // XBIOS
                addq.l  #6,sp
                bras    done


// exception handler
exception:      move.l  a1,sp           // restore stack (SSP)
                jmp     (a0)            // and continue


super:          move.l  (0x10),-(sp)
                move.l  (0x2c),-(sp)
                move.l  (0xf4),-(sp)
                move.l  sp,a1           // save stack pointer (SSP)

        // set exception vectors
                lea     exception(pc),a0
                move.l  a0,(0x10)
                move.l  a0,(0x2c)
                move.l  a0,(0xf4)
                nop                     // flush write pipeline

        // try 68040 / 68060
                lea     fc1(pc),a0
                dc.w    0xf4f8          // cpusha bc            // [m68040]
                bras    ret
fc1:
        // try 68030
                lea     fc2(pc),a0
                dc.w    0x4e7a, 0x0002  // movec.l cacr,d0      // [m68030]
                move.l  d0,d1
                or.w    #0x0808,d1
                dc.w    0x4e7b, 0x1002  // movec.l d1,cacr      // [m68030]
                dc.w    0x4e7b, 0x0002  // movec.l d0,cacr      // [m68030]
//                bras    ret
fc2:

ret:            move.l  (sp)+,(0xf4)
                move.l  (sp)+,(0x2c)
                move.l  (sp)+,(0x10)
                nop                     // flush write pipeline
                rts

done:
        endm



macro(BOTH_FLUSH_CACHE)
                local   done
                MINT_FLUSH_CACHE
                tst.l   d0
                beqs    done
                SUPEXEC_FLUSH_CACHE
done:
        endm



#define ASTACK          a7

#if 1
#  define FLUSH_CACHE   BOTH_FLUSH_CACHE
#elif 0
#  define FLUSH_CACHE   MINT_FLUSH_CACHE
#else
#  undef FLUSH_CACHE
#endif



/*************************************************************************
// entry - the text segment of a compressed executable
//
// note: compressed programs never have the F_SHTEXT flag set,
//       so we can assume that the text, data & bss segments
//       are contiguous in memory
**************************************************************************/

section tos0

start:
                move.l  a0,d0           // a0 is basepage if accessory
                beqs    1f
                move.l  4(a0),sp        // accessory - get stack
                bras    2f

1:              move.l  4(sp),d0        // application - get basepage
2:              movem.l d1-d7/a0-a6,-(sp)


// ------------- restore original basepage

        // we also setup d4 and a6 here, and we prepare a4

                move.l  d0,a2           // a2 = basepage
                addq.l  #p_tbase,a2
                move.l  (a2)+,a6
                move.l  a6,d4                   // d4 = p_tbase
                move.l  #up11,(a2)      // p_tlen
                add.l   (a2)+,a6
                move.l  a6,(a2)+        // p_dbase
                move.l  #up12,(a2)      // p_dlen
                add.l   (a2)+,a6                // a6 = decompressed p_bbase
                move.l  (a2),a4                 // a4 = compressed p_bbase
                move.l  a6,(a2)+        // p_bbase
                move.l  #up13,(a2)      // p_blen


// ------------- copy data segment (from a4 to a3, downwards)

                // a4 (top of compressed data) already initialized above

                move.l  d4,a3
                add.l   #up21,a3        // top of data segment + offset


                // number of loops
section loop1_set_count.b
                moveq.l #loop1_count,d0
section loop1_set_count.w
                move.w  #loop1_count,d0
section loop1_set_count.l
                move.l  #loop1_count,d0

section loop1_label
loop1:


section loop1.small
        // copy 4 bytes per loop
                move.l  -(a4),-(a3)
section loop1_subql
                subq.l  #1,d0
                bnes    loop1
section loop1_subqw
                subq.w  #1,d0
                bnes    loop1
section loop1_dbra
                dbra    d0,loop1

section loop2.small
        // loop2 - EMPTY section


section loop1.fast
        // loop1 - use 10 registers to copy 4*10*4 = 160 bytes per loop
                lea.l   -160(a4),a4
                movem.l 120(a4),d1-d3/d5-d7/a0-a2/a5
                movem.l d1-d3/d5-d7/a0-a2/a5,-(a3)
                movem.l 80(a4),d1-d3/d5-d7/a0-a2/a5
                movem.l d1-d3/d5-d7/a0-a2/a5,-(a3)
                movem.l 40(a4),d1-d3/d5-d7/a0-a2/a5
                movem.l d1-d3/d5-d7/a0-a2/a5,-(a3)
                movem.l (a4),d1-d3/d5-d7/a0-a2/a5
                movem.l d1-d3/d5-d7/a0-a2/a5,-(a3)

section loop2.fast
        // loop2 - copy the remaining 4..160 bytes
                moveq.l  #loop2_count,d0
loop2:          move.l  -(a4),-(a3)
                dbra    d0,loop2


        // a3 now points to the start of the compressed block


// ------------- copy code to stack and setup ASTACK

section copy_to_stack

// Copy the final startup code below the stack. This will get
// called via "jmp (ASTACK)" after decompression and relocation.

                lea.l   clear_bss_end:w(pc),a2
                move.l  d4,-(ASTACK)    // entry point for final jmp

                //moveq.l #((clear_bss_end-clear_bss)/2-1),d5
                moveq.l #copy_to_stack_len,d5
loop6:          move.w  -(a2),-(ASTACK)
                subq.l  #1,d5
                bccs    loop6

#ifdef FLUSH_CACHE
                // patch code: on the stack, the `rts' becomes a `nop'
                //move.w  #0x4e71,(flush_cache_rts-clear_bss):w(ASTACK)
                move.w  #0x4e71,flush_cache_rts_offset:w(ASTACK)
#endif

        // note: d5.l is now -1 (needed for decompressor)


// -------------

#ifdef FLUSH_CACHE
                bsrs    flush_cache
#endif


// ------------- prepare decompressor

#define NRV_NO_INIT

section nrv2b.init
                //moveq.l #-1,d5          // last_off = -1
                moveq.l #-128,d0        // d0.b = $80
                moveq.l #-1,d7
                moveq.l #-0x68,d6       // 0xffffff98
                lsl.w   #5,d6           // 0xfffff300 == -0xd00
section nrv2d.init
                //moveq.l #-1,d5          // last_off = -1
                moveq.l #-128,d0        // d0.b = $80
                moveq.l #-1,d7
                moveq.l #-0x50,d6       // 0xffffffb0
                lsl.w   #4,d6           // 0xfffffb00 == -0x500
section nrv2e.init
                //moveq.l #-1,d5          // last_off = -1
                moveq.l #-128,d0        // d0.b = $80
                moveq.l #0,d7
                moveq.l #-0x50,d6       // 0xffffffb0
                lsl.w   #4,d6           // 0xfffffb00 == -0x500


// ------------- jump to copied decompressor

section jmp_decompressor
        // a3 still points to the start of the compressed block
                move.l  d4,a4           // dest. for decompressing

                move.l  d4,a2
                add.l   #up31,a2
                jmp     (a2)            // jmp decompr_start


/*************************************************************************
// this is the final part of the startup code which runs in the stack
**************************************************************************/

// ------------- clear dirty bss

section clear_bss

        // on entry:
        //   ASTACK      == pc == clear_bss (on stack)
        //   a6          start of dirty bss [long living register]
        //   d6.l        number of clr loops
        //   d3.l        0


section loop3_label:
loop3:
section loop3.small:
                move.l  d3,(a6)+
section loop3.fast:
        // the dirty bss is usually not too large, so we don't
        // bother making movem optimizations here
                move.l  d3,(a6)+
                move.l  d3,(a6)+
                move.l  d3,(a6)+
                move.l  d3,(a6)+
section loop3_subql
                subq.l  #1,d6
                bnes    loop3
section loop3_subqw
                subq.w  #1,d6
                bnes    loop3
section loop3_dbra
                dbra    d6,loop3


// ------------- flush the cache

#ifdef FLUSH_CACHE

// info:
//  This is also called as a subroutine (before decompression, NOT running
//  in the stack). When running in the stack the `rts' is replaced by a `nop'.

section flush_cache
                FLUSH_CACHE
flush_cache_rts:
                rts

#endif


// ------------- restore ASTACK

                lea     clear_bss_size_p4:w(ASTACK),sp

        // assert sp == clear_bss_end(pc)+4


// ------------- clear the dirty stack

section clear_dirty_stack

                // clear down to clear_bss(pc) + 32 extra longs
                //moveq.l #((L(loop)-clear_bss+3)/4+32-1),d0
                moveq.l #clear_dirty_stack_len,d0
                lea     1f(pc),a0
1:              move.l  d3,-(a0)
                dbra    d0,1b


// ------------- start program

section start_program

                movem.l (sp)+,d1-d7/a0-a6
                move.l  a0,d0
                beqs    1f
                sub.l   sp,sp           // accessory: no stack
1:              dc.w    0x4ef9          // jmp $xxxxxxxx - jmp to text segment


.globl clear_bss_end    // for clear_dirty_stack_len
clear_bss_end:


/*************************************************************************
// UPX ident & packheader
**************************************************************************/

// IDENTSTR

// align4

#include "include/header.S"


        // end of text segment - size is a multiple of 4


/*************************************************************************
// This part is appended after the compressed data.
// It runs in the last part of the dirty bss (after the
// relocations and the original fileheader).
**************************************************************************/

section CUTPOINT

// ------------- decompress (from a3 to a4)

#define a0 A3
#define a1 A4
#define a3 A2
#define d2 D3


#define L(label)      .L ## label
#define NRV_BB  8
#undef SMALL

section nrv2b_8.fast
#  define N(x)  nrv2b_8_fast_ ## x
#  include "arch/m68k/rename.ash"
#  include "arch/m68k/nrv2b_d.ash"
#  undef N

section nrv2d_8.fast
#  define N(x)  nrv2d_8_fast_ ## x
#  include "arch/m68k/rename.ash"
#  include "arch/m68k/nrv2d_d.ash"
#  undef N

section nrv2e_8.fast
#  define N(x)  nrv2e_8_fast_ ## x
#  include "arch/m68k/rename.ash"
#  include "arch/m68k/nrv2e_d.ash"
#  undef N


#define SMALL 1

section nrv2b_8.small
#  define N(x)  nrv2b_8_small_ ## x
#  include "arch/m68k/rename.ash"
#  include "arch/m68k/nrv2b_d.ash"
#  undef N

section nrv2d_8.small
#  define N(x)  nrv2d_8_small_ ## x
#  include "arch/m68k/rename.ash"
#  include "arch/m68k/nrv2d_d.ash"
#  undef N

section nrv2e_8.small
#  define N(x)  nrv2e_8_small_ ## x
#  include "arch/m68k/rename.ash"
#  include "arch/m68k/nrv2e_d.ash"
#  undef N


#include "arch/m68k/rename.ash"
#undef L
#undef NRV_BB
#undef SMALL

#undef a0
#undef a1
#undef a3
#undef d2


        // note: d3.l is 0 from decompressor above


// ------------- support

section __mulsi3
#if 0
                // compute high-word
                move.w  4(sp),d1                // 12
                move.w  6(sp),d0                // 12
                mulu.w  8(sp),d0                // 78
                mulu.w  10(sp),d1               // 78
                add.w   d1,d0                   //  4
                swap    d0                      //  4
                clr.w   d0                      //  4
                // add low-word
                move.w  6(sp),d1                // 12
                mulu.w  10(sp),d1               // 78
                add.l   d1,d0                   //  6
                rts                             // 16
#else
    // smaller and faster
                // compute high-word
                lea     4(sp),a0                //  8
                move.w  (a0)+,d1                //  8
                move.w  (a0)+,d0                //  8
                mulu.w  (a0)+,d0                // 74
                mulu.w  (a0),d1                 // 74
                add.w   d1,d0                   //  4
                swap    d0                      //  4
                clr.w   d0                      //  4
                // add low-word
                move.w  6(sp),d1                // 12
                mulu.w  (a0),d1                 // 74
                add.l   d1,d0                   //  6
                rts                             // 16
#endif


// ------------- reloc

section reloc

// The decompressed relocations now are just after the decompressed
// data segment, i.e. at the beginning of the (dirty) bss.

        // note: d3.l is still 0

                move.l  a6,a0           // a0 = start of relocations
                moveq.l #1,d5

                move.l  d4,a1
                add.l   (a0)+,a1        // get initial fixup

1:              add.l   d3,a1           // increase fixup
                add.l   d4,(a1)         // reloc one address
2:              move.b  (a0)+,d3
                beqs    3f
                cmp.b   d5,d3           // note: d5.b is #1 from above
                bnes    1b
                lea     254(a1),a1      // d3 == 1 -> add 254, don't reloc
                bras    2b
3:


// ------------- clear dirty bss & start program

                // number of loops
section loop3_set_count.b
                moveq.l #loop3_count,d6
section loop3_set_count.w
                move.w  #loop3_count,d6
section loop3_set_count.l
                move.l  #loop3_count,d6


section jmpstack

// We are currently running in the dirty bss.
// Jump to the code we copied below the stack.

                jmp     (ASTACK)        // jmp clear_bss (on stack)


// ------------- absolute symbols ("*ABS*")

section abs_symbols

#define N(a,b) \
    .globl a##_##b##_start_offset; \
     a##_##b##_start_offset = a##_##b##_decompr_start - a.b
N(nrv2b_8,fast)
N(nrv2d_8,fast)
N(nrv2e_8,fast)
N(nrv2b_8,small)
N(nrv2d_8,small)
N(nrv2e_8,small)
#undef N

#define N(a,b) \
    .globl a##_##b##_start_offset; a##_##b##_start_offset = 0
N(lzma,fast)
N(lzma,small)
#undef N


// vi:ts=8:et:nowrap

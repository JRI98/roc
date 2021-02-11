use crate::generic64::{Assembler, CallConv, RegTrait};
use crate::Relocation;
use bumpalo::collections::Vec;

// Not sure exactly how I want to represent registers.
// If we want max speed, we would likely make them structs that impl the same trait to avoid ifs.
#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Debug)]
pub enum X86_64GeneralReg {
    RAX = 0,
    RCX = 1,
    RDX = 2,
    RBX = 3,
    RSP = 4,
    RBP = 5,
    RSI = 6,
    RDI = 7,
    R8 = 8,
    R9 = 9,
    R10 = 10,
    R11 = 11,
    R12 = 12,
    R13 = 13,
    R14 = 14,
    R15 = 15,
}
impl RegTrait for X86_64GeneralReg {}

#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Debug)]
pub enum X86_64FloatReg {
    XMM0 = 0,
    XMM1 = 1,
    XMM2 = 2,
    XMM3 = 3,
    XMM4 = 4,
    XMM5 = 5,
    XMM6 = 6,
    XMM7 = 7,
    XMM8 = 8,
    XMM9 = 9,
    XMM10 = 10,
    XMM11 = 11,
    XMM12 = 12,
    XMM13 = 13,
    XMM14 = 14,
    XMM15 = 15,
}
impl RegTrait for X86_64FloatReg {}

pub struct X86_64Assembler {}
pub struct X86_64WindowsFastcall {}
pub struct X86_64SystemV {}

const STACK_ALIGNMENT: u8 = 16;

impl CallConv<X86_64GeneralReg, X86_64FloatReg> for X86_64SystemV {
    const GENERAL_PARAM_REGS: &'static [X86_64GeneralReg] = &[
        X86_64GeneralReg::RDI,
        X86_64GeneralReg::RSI,
        X86_64GeneralReg::RDX,
        X86_64GeneralReg::RCX,
        X86_64GeneralReg::R8,
        X86_64GeneralReg::R9,
    ];
    const GENERAL_RETURN_REGS: &'static [X86_64GeneralReg] =
        &[X86_64GeneralReg::RAX, X86_64GeneralReg::RDX];
    const GENERAL_DEFAULT_FREE_REGS: &'static [X86_64GeneralReg] = &[
        // The regs we want to use first should be at the end of this vec.
        // We will use pop to get which reg to use next
        // Use callee saved regs last.
        X86_64GeneralReg::RBX,
        // Don't use frame pointer: X86_64GeneralReg::RBP,
        X86_64GeneralReg::R12,
        X86_64GeneralReg::R13,
        X86_64GeneralReg::R14,
        X86_64GeneralReg::R15,
        // Use caller saved regs first.
        X86_64GeneralReg::RAX,
        X86_64GeneralReg::RCX,
        X86_64GeneralReg::RDX,
        // Don't use stack pionter: X86_64GeneralReg::RSP,
        X86_64GeneralReg::RSI,
        X86_64GeneralReg::RDI,
        X86_64GeneralReg::R8,
        X86_64GeneralReg::R9,
        X86_64GeneralReg::R10,
        X86_64GeneralReg::R11,
    ];

    const FLOAT_PARAM_REGS: &'static [X86_64FloatReg] = &[
        X86_64FloatReg::XMM0,
        X86_64FloatReg::XMM1,
        X86_64FloatReg::XMM2,
        X86_64FloatReg::XMM3,
        X86_64FloatReg::XMM4,
        X86_64FloatReg::XMM5,
        X86_64FloatReg::XMM6,
        X86_64FloatReg::XMM7,
    ];
    const FLOAT_RETURN_REGS: &'static [X86_64FloatReg] =
        &[X86_64FloatReg::XMM0, X86_64FloatReg::XMM1];
    const FLOAT_DEFAULT_FREE_REGS: &'static [X86_64FloatReg] = &[
        // The regs we want to use first should be at the end of this vec.
        // We will use pop to get which reg to use next
        // No callee saved regs.
        // Use caller saved regs first.
        X86_64FloatReg::XMM15,
        X86_64FloatReg::XMM14,
        X86_64FloatReg::XMM13,
        X86_64FloatReg::XMM12,
        X86_64FloatReg::XMM11,
        X86_64FloatReg::XMM10,
        X86_64FloatReg::XMM9,
        X86_64FloatReg::XMM8,
        X86_64FloatReg::XMM7,
        X86_64FloatReg::XMM6,
        X86_64FloatReg::XMM5,
        X86_64FloatReg::XMM4,
        X86_64FloatReg::XMM3,
        X86_64FloatReg::XMM2,
        X86_64FloatReg::XMM1,
        X86_64FloatReg::XMM0,
    ];
    const SHADOW_SPACE_SIZE: u8 = 0;

    #[inline(always)]
    fn general_callee_saved(reg: &X86_64GeneralReg) -> bool {
        matches!(
            reg,
            X86_64GeneralReg::RBX
                | X86_64GeneralReg::RBP
                | X86_64GeneralReg::R12
                | X86_64GeneralReg::R13
                | X86_64GeneralReg::R14
                | X86_64GeneralReg::R15
        )
    }

    #[inline(always)]
    fn float_callee_saved(_reg: &X86_64FloatReg) -> bool {
        false
    }

    #[inline(always)]
    fn setup_stack<'a>(
        buf: &mut Vec<'a, u8>,
        leaf_function: bool,
        general_saved_regs: &[X86_64GeneralReg],
        requested_stack_size: i32,
    ) -> Result<i32, String> {
        x86_64_generic_setup_stack(buf, leaf_function, general_saved_regs, requested_stack_size)
    }

    #[inline(always)]
    fn cleanup_stack<'a>(
        buf: &mut Vec<'a, u8>,
        leaf_function: bool,
        general_saved_regs: &[X86_64GeneralReg],
        aligned_stack_size: i32,
    ) -> Result<(), String> {
        x86_64_generic_cleanup_stack(buf, leaf_function, general_saved_regs, aligned_stack_size)
    }
}

impl CallConv<X86_64GeneralReg, X86_64FloatReg> for X86_64WindowsFastcall {
    const GENERAL_PARAM_REGS: &'static [X86_64GeneralReg] = &[
        X86_64GeneralReg::RCX,
        X86_64GeneralReg::RDX,
        X86_64GeneralReg::R8,
        X86_64GeneralReg::R9,
    ];
    const GENERAL_RETURN_REGS: &'static [X86_64GeneralReg] = &[X86_64GeneralReg::RAX];
    const GENERAL_DEFAULT_FREE_REGS: &'static [X86_64GeneralReg] = &[
        // The regs we want to use first should be at the end of this vec.
        // We will use pop to get which reg to use next

        // Don't use stack pionter: X86_64GeneralReg::RSP,
        // Don't use frame pointer: X86_64GeneralReg::RBP,

        // Use callee saved regs last.
        X86_64GeneralReg::RBX,
        X86_64GeneralReg::RSI,
        X86_64GeneralReg::RDI,
        X86_64GeneralReg::R12,
        X86_64GeneralReg::R13,
        X86_64GeneralReg::R14,
        X86_64GeneralReg::R15,
        // Use caller saved regs first.
        X86_64GeneralReg::RAX,
        X86_64GeneralReg::RCX,
        X86_64GeneralReg::RDX,
        X86_64GeneralReg::R8,
        X86_64GeneralReg::R9,
        X86_64GeneralReg::R10,
        X86_64GeneralReg::R11,
    ];
    const FLOAT_PARAM_REGS: &'static [X86_64FloatReg] = &[
        X86_64FloatReg::XMM0,
        X86_64FloatReg::XMM1,
        X86_64FloatReg::XMM2,
        X86_64FloatReg::XMM3,
    ];
    const FLOAT_RETURN_REGS: &'static [X86_64FloatReg] = &[X86_64FloatReg::XMM0];
    const FLOAT_DEFAULT_FREE_REGS: &'static [X86_64FloatReg] = &[
        // The regs we want to use first should be at the end of this vec.
        // We will use pop to get which reg to use next
        // Use callee saved regs last.
        X86_64FloatReg::XMM15,
        X86_64FloatReg::XMM15,
        X86_64FloatReg::XMM13,
        X86_64FloatReg::XMM12,
        X86_64FloatReg::XMM11,
        X86_64FloatReg::XMM10,
        X86_64FloatReg::XMM9,
        X86_64FloatReg::XMM8,
        X86_64FloatReg::XMM7,
        X86_64FloatReg::XMM6,
        // Use caller saved regs first.
        X86_64FloatReg::XMM5,
        X86_64FloatReg::XMM4,
        X86_64FloatReg::XMM3,
        X86_64FloatReg::XMM2,
        X86_64FloatReg::XMM1,
        X86_64FloatReg::XMM0,
    ];
    const SHADOW_SPACE_SIZE: u8 = 32;

    #[inline(always)]
    fn general_callee_saved(reg: &X86_64GeneralReg) -> bool {
        matches!(
            reg,
            X86_64GeneralReg::RBX
                | X86_64GeneralReg::RBP
                | X86_64GeneralReg::RSI
                | X86_64GeneralReg::RSP
                | X86_64GeneralReg::RDI
                | X86_64GeneralReg::R12
                | X86_64GeneralReg::R13
                | X86_64GeneralReg::R14
                | X86_64GeneralReg::R15
        )
    }

    #[inline(always)]
    fn float_callee_saved(reg: &X86_64FloatReg) -> bool {
        matches!(
            reg,
            X86_64FloatReg::XMM0
                | X86_64FloatReg::XMM1
                | X86_64FloatReg::XMM2
                | X86_64FloatReg::XMM3
                | X86_64FloatReg::XMM4
                | X86_64FloatReg::XMM5
        )
    }

    #[inline(always)]
    fn setup_stack<'a>(
        buf: &mut Vec<'a, u8>,
        leaf_function: bool,
        saved_regs: &[X86_64GeneralReg],
        requested_stack_size: i32,
    ) -> Result<i32, String> {
        x86_64_generic_setup_stack(buf, leaf_function, saved_regs, requested_stack_size)
    }

    #[inline(always)]
    fn cleanup_stack<'a>(
        buf: &mut Vec<'a, u8>,
        leaf_function: bool,
        saved_regs: &[X86_64GeneralReg],
        aligned_stack_size: i32,
    ) -> Result<(), String> {
        x86_64_generic_cleanup_stack(buf, leaf_function, saved_regs, aligned_stack_size)
    }
}

#[inline(always)]
fn x86_64_generic_setup_stack<'a>(
    buf: &mut Vec<'a, u8>,
    leaf_function: bool,
    saved_regs: &[X86_64GeneralReg],
    requested_stack_size: i32,
) -> Result<i32, String> {
    if !leaf_function {
        X86_64Assembler::push_reg64(buf, X86_64GeneralReg::RBP);
        X86_64Assembler::mov_reg64_reg64(buf, X86_64GeneralReg::RBP, X86_64GeneralReg::RSP);
    }
    for reg in saved_regs {
        X86_64Assembler::push_reg64(buf, *reg);
    }

    // full size is upcast to i64 to make sure we don't overflow here.
    let full_size = 8 * saved_regs.len() as i64 + requested_stack_size as i64;
    let alignment = if full_size <= 0 {
        0
    } else {
        full_size % STACK_ALIGNMENT as i64
    };
    let offset = if alignment == 0 {
        0
    } else {
        STACK_ALIGNMENT - alignment as u8
    };
    if let Some(aligned_stack_size) = requested_stack_size.checked_add(offset as i32) {
        if aligned_stack_size > 0 {
            X86_64Assembler::sub_reg64_reg64_imm32(
                buf,
                X86_64GeneralReg::RSP,
                X86_64GeneralReg::RSP,
                aligned_stack_size,
            );
            Ok(aligned_stack_size)
        } else {
            Ok(0)
        }
    } else {
        Err("Ran out of stack space".to_string())
    }
}

#[inline(always)]
fn x86_64_generic_cleanup_stack<'a>(
    buf: &mut Vec<'a, u8>,
    leaf_function: bool,
    saved_regs: &[X86_64GeneralReg],
    aligned_stack_size: i32,
) -> Result<(), String> {
    if aligned_stack_size > 0 {
        X86_64Assembler::add_reg64_reg64_imm32(
            buf,
            X86_64GeneralReg::RSP,
            X86_64GeneralReg::RSP,
            aligned_stack_size,
        );
    }
    for reg in saved_regs.iter().rev() {
        X86_64Assembler::pop_reg64(buf, *reg);
    }
    if !leaf_function {
        X86_64Assembler::mov_reg64_reg64(buf, X86_64GeneralReg::RSP, X86_64GeneralReg::RBP);
        X86_64Assembler::pop_reg64(buf, X86_64GeneralReg::RBP);
    }
    Ok(())
}

impl Assembler<X86_64GeneralReg, X86_64FloatReg> for X86_64Assembler {
    // These functions should map to the raw assembly functions below.
    // In some cases, that means you can just directly call one of the direct assembly functions.
    #[inline(always)]
    fn abs_reg64_reg64(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, src: X86_64GeneralReg) {
        mov_reg64_reg64(buf, dst, src);
        neg_reg64(buf, dst);
        cmovl_reg64_reg64(buf, dst, src);
    }
    #[inline(always)]
    fn add_reg64_reg64_imm32(
        buf: &mut Vec<'_, u8>,
        dst: X86_64GeneralReg,
        src1: X86_64GeneralReg,
        imm32: i32,
    ) {
        if dst == src1 {
            add_reg64_imm32(buf, dst, imm32);
        } else {
            mov_reg64_reg64(buf, dst, src1);
            add_reg64_imm32(buf, dst, imm32);
        }
    }
    #[inline(always)]
    fn add_reg64_reg64_reg64(
        buf: &mut Vec<'_, u8>,
        dst: X86_64GeneralReg,
        src1: X86_64GeneralReg,
        src2: X86_64GeneralReg,
    ) {
        if dst == src1 {
            add_reg64_reg64(buf, dst, src2);
        } else if dst == src2 {
            add_reg64_reg64(buf, dst, src1);
        } else {
            mov_reg64_reg64(buf, dst, src1);
            add_reg64_reg64(buf, dst, src2);
        }
    }
    #[inline(always)]
    fn add_freg64_freg64_freg64(
        buf: &mut Vec<'_, u8>,
        dst: X86_64FloatReg,
        src1: X86_64FloatReg,
        src2: X86_64FloatReg,
    ) {
        if dst == src1 {
            addsd_freg64_freg64(buf, dst, src2);
        } else if dst == src2 {
            addsd_freg64_freg64(buf, dst, src1);
        } else {
            movsd_freg64_freg64(buf, dst, src1);
            addsd_freg64_freg64(buf, dst, src2);
        }
    }
    #[inline(always)]
    fn call(buf: &mut Vec<'_, u8>, relocs: &mut Vec<'_, Relocation>, fn_name: String) {
        buf.extend(&[0xE8, 0x00, 0x00, 0x00, 0x00]);
        relocs.push(Relocation::LinkedFunction {
            offset: buf.len() as u64 - 4,
            name: fn_name,
        });
    }
    #[inline(always)]
    fn mov_freg64_imm64(
        buf: &mut Vec<'_, u8>,
        relocs: &mut Vec<'_, Relocation>,
        dst: X86_64FloatReg,
        imm: f64,
    ) {
        movsd_freg64_rip_offset32(buf, dst, 0);
        relocs.push(Relocation::LocalData {
            offset: buf.len() as u64 - 4,
            data: imm.to_le_bytes().to_vec(),
        });
    }
    #[inline(always)]
    fn mov_reg64_imm64(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, imm: i64) {
        mov_reg64_imm64(buf, dst, imm);
    }
    #[inline(always)]
    fn mov_freg64_freg64(buf: &mut Vec<'_, u8>, dst: X86_64FloatReg, src: X86_64FloatReg) {
        movsd_freg64_freg64(buf, dst, src);
    }
    #[inline(always)]
    fn mov_reg64_reg64(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, src: X86_64GeneralReg) {
        mov_reg64_reg64(buf, dst, src);
    }
    #[inline(always)]
    fn mov_freg64_stack32(_buf: &mut Vec<'_, u8>, _dst: X86_64FloatReg, _offset: i32) {
        unimplemented!("loading floating point reg from stack not yet implemented for X86_64");
    }
    #[inline(always)]
    fn mov_reg64_stack32(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, offset: i32) {
        mov_reg64_stack32(buf, dst, offset);
    }
    #[inline(always)]
    fn mov_stack32_freg64(_buf: &mut Vec<'_, u8>, _offset: i32, _src: X86_64FloatReg) {
        unimplemented!("saving floating point reg to stack not yet implemented for X86_64");
    }
    #[inline(always)]
    fn mov_stack32_reg64(buf: &mut Vec<'_, u8>, offset: i32, src: X86_64GeneralReg) {
        mov_stack32_reg64(buf, offset, src);
    }
    #[inline(always)]
    fn sub_reg64_reg64_imm32(
        buf: &mut Vec<'_, u8>,
        dst: X86_64GeneralReg,
        src1: X86_64GeneralReg,
        imm32: i32,
    ) {
        if dst == src1 {
            sub_reg64_imm32(buf, dst, imm32);
        } else {
            mov_reg64_reg64(buf, dst, src1);
            sub_reg64_imm32(buf, dst, imm32);
        }
    }
    #[inline(always)]
    fn sub_reg64_reg64_reg64(
        buf: &mut Vec<'_, u8>,
        dst: X86_64GeneralReg,
        src1: X86_64GeneralReg,
        src2: X86_64GeneralReg,
    ) {
        if dst == src1 {
            sub_reg64_reg64(buf, dst, src2);
        } else {
            mov_reg64_reg64(buf, dst, src1);
            sub_reg64_reg64(buf, dst, src2);
        }
    }

    #[inline(always)]
    fn eq_reg64_reg64_reg64(
        buf: &mut Vec<'_, u8>,
        dst: X86_64GeneralReg,
        src1: X86_64GeneralReg,
        src2: X86_64GeneralReg,
    ) {
        cmp_reg64_reg64(buf, src1, src2);
        sete_reg64(buf, dst);
    }

    #[inline(always)]
    fn ret(buf: &mut Vec<'_, u8>) {
        ret(buf);
    }
}

impl X86_64Assembler {
    #[inline(always)]
    fn pop_reg64(buf: &mut Vec<'_, u8>, reg: X86_64GeneralReg) {
        pop_reg64(buf, reg);
    }

    #[inline(always)]
    fn push_reg64(buf: &mut Vec<'_, u8>, reg: X86_64GeneralReg) {
        push_reg64(buf, reg);
    }
}
const REX: u8 = 0x40;
const REX_W: u8 = REX + 0x8;

#[inline(always)]
const fn add_rm_extension(reg: X86_64GeneralReg, byte: u8) -> u8 {
    if reg as u8 > 7 {
        byte + 1
    } else {
        byte
    }
}

#[inline(always)]
const fn add_opcode_extension(reg: X86_64GeneralReg, byte: u8) -> u8 {
    add_rm_extension(reg, byte)
}

#[inline(always)]
const fn add_reg_extension(reg: X86_64GeneralReg, byte: u8) -> u8 {
    if reg as u8 > 7 {
        byte + 4
    } else {
        byte
    }
}

// Below here are the functions for all of the assembly instructions.
// Their names are based on the instruction and operators combined.
// You should call `buf.reserve()` if you push or extend more than once.
// Unit tests are added at the bottom of the file to ensure correct asm generation.
// Please keep these in alphanumeric order.
/// `ADD r/m64, imm32` -> Add imm32 sign-extended to 64-bits from r/m64.
#[inline(always)]
fn add_reg64_imm32(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, imm: i32) {
    // This can be optimized if the immediate is 1 byte.
    let rex = add_rm_extension(dst, REX_W);
    let dst_mod = dst as u8 % 8;
    buf.reserve(7);
    buf.extend(&[rex, 0x81, 0xC0 + dst_mod]);
    buf.extend(&imm.to_le_bytes());
}

fn binop_reg64_reg64(
    op_code: u8,
    buf: &mut Vec<'_, u8>,
    dst: X86_64GeneralReg,
    src: X86_64GeneralReg,
) {
    let rex = add_rm_extension(dst, REX_W);
    let rex = add_reg_extension(src, rex);
    let dst_mod = dst as u8 % 8;
    let src_mod = (src as u8 % 8) << 3;
    buf.extend(&[rex, op_code, 0xC0 + dst_mod + src_mod]);
}

/// `ADD r/m64,r64` -> Add r64 to r/m64.
#[inline(always)]
fn add_reg64_reg64(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, src: X86_64GeneralReg) {
    binop_reg64_reg64(0x01, buf, dst, src);
}

/// `ADDSD xmm1,xmm2/m64` -> Add the low double-precision floating-point value from xmm2/mem to xmm1 and store the result in xmm1.
#[inline(always)]
fn addsd_freg64_freg64(buf: &mut Vec<'_, u8>, dst: X86_64FloatReg, src: X86_64FloatReg) {
    let dst_high = dst as u8 > 7;
    let dst_mod = dst as u8 % 8;
    let src_high = src as u8 > 7;
    let src_mod = src as u8 % 8;
    if dst_high || src_high {
        buf.extend(&[
            0xF2,
            0x40 + ((dst_high as u8) << 2) + (src_high as u8),
            0x0F,
            0x58,
            0xC0 + (dst_mod << 3) + (src_mod),
        ])
    } else {
        buf.extend(&[0xF2, 0x0F, 0x58, 0xC0 + (dst_mod << 3) + (src_mod)])
    }
}

/// `SUB r/m64,r64` -> Sub r64 to r/m64.
#[inline(always)]
fn sub_reg64_reg64(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, src: X86_64GeneralReg) {
    binop_reg64_reg64(0x29, buf, dst, src);
}

/// `CMP r/m64,r64` -> Compare r64 to r/m64.
#[inline(always)]
fn cmp_reg64_reg64(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, src: X86_64GeneralReg) {
    binop_reg64_reg64(0x39, buf, dst, src);
}

/// `XOR r/m64,r64` -> Xor r64 to r/m64.
#[inline(always)]
fn xor_reg64_reg64(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, src: X86_64GeneralReg) {
    binop_reg64_reg64(0x31, buf, dst, src);
}

/// `CMOVL r64,r/m64` -> Move if less (SF≠ OF).
#[inline(always)]
fn cmovl_reg64_reg64(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, src: X86_64GeneralReg) {
    let rex = add_reg_extension(dst, REX_W);
    let rex = add_rm_extension(src, rex);
    let dst_mod = (dst as u8 % 8) << 3;
    let src_mod = src as u8 % 8;
    buf.extend(&[rex, 0x0F, 0x4C, 0xC0 + dst_mod + src_mod]);
}

/// `MOV r/m64, imm32` -> Move imm32 sign extended to 64-bits to r/m64.
#[inline(always)]
fn mov_reg64_imm32(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, imm: i32) {
    let rex = add_rm_extension(dst, REX_W);
    let dst_mod = dst as u8 % 8;
    buf.reserve(7);
    buf.extend(&[rex, 0xC7, 0xC0 + dst_mod]);
    buf.extend(&imm.to_le_bytes());
}

/// `MOV r64, imm64` -> Move imm64 to r64.
#[inline(always)]
fn mov_reg64_imm64(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, imm: i64) {
    if imm <= i32::MAX as i64 && imm >= i32::MIN as i64 {
        mov_reg64_imm32(buf, dst, imm as i32)
    } else {
        let rex = add_opcode_extension(dst, REX_W);
        let dst_mod = dst as u8 % 8;
        buf.reserve(10);
        buf.extend(&[rex, 0xB8 + dst_mod]);
        buf.extend(&imm.to_le_bytes());
    }
}

/// `MOV r/m64,r64` -> Move r64 to r/m64.
#[inline(always)]
fn mov_reg64_reg64(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, src: X86_64GeneralReg) {
    binop_reg64_reg64(0x89, buf, dst, src);
}

/// `MOV r64,r/m64` -> Move r/m64 to r64.
#[inline(always)]
fn mov_reg64_stack32(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, offset: i32) {
    // This can be optimized based on how many bytes the offset actually is.
    // This function can probably be made to take any memory offset, I didn't feel like figuring it out rn.
    // Also, this may technically be faster genration since stack operations should be so common.
    let rex = add_reg_extension(dst, REX_W);
    let dst_mod = (dst as u8 % 8) << 3;
    buf.reserve(8);
    buf.extend(&[rex, 0x8B, 0x84 + dst_mod, 0x24]);
    buf.extend(&offset.to_le_bytes());
}

/// `MOV r/m64,r64` -> Move r64 to r/m64.
#[inline(always)]
fn mov_stack32_reg64(buf: &mut Vec<'_, u8>, offset: i32, src: X86_64GeneralReg) {
    // This can be optimized based on how many bytes the offset actually is.
    // This function can probably be made to take any memory offset, I didn't feel like figuring it out rn.
    // Also, this may technically be faster genration since stack operations should be so common.
    let rex = add_reg_extension(src, REX_W);
    let src_mod = (src as u8 % 8) << 3;
    buf.reserve(8);
    buf.extend(&[rex, 0x89, 0x84 + src_mod, 0x24]);
    buf.extend(&offset.to_le_bytes());
}

/// `MOVSD xmm1,xmm2` -> Move scalar double-precision floating-point value from xmm2 to xmm1 register.
#[inline(always)]
fn movsd_freg64_freg64(buf: &mut Vec<'_, u8>, dst: X86_64FloatReg, src: X86_64FloatReg) {
    let dst_high = dst as u8 > 7;
    let dst_mod = dst as u8 % 8;
    let src_high = src as u8 > 7;
    let src_mod = src as u8 % 8;
    if dst_high || src_high {
        buf.extend(&[
            0xF2,
            0x40 + ((dst_high as u8) << 2) + (src_high as u8),
            0x0F,
            0x10,
            0xC0 + (dst_mod << 3) + (src_mod),
        ])
    } else {
        buf.extend(&[0xF2, 0x0F, 0x10, 0xC0 + (dst_mod << 3) + (src_mod)])
    }
}

// `MOVSD xmm, m64` -> Load scalar double-precision floating-point value from m64 to xmm register.
fn movsd_freg64_rip_offset32(buf: &mut Vec<'_, u8>, dst: X86_64FloatReg, offset: u32) {
    let dst_mod = dst as u8 % 8;
    if dst as u8 > 7 {
        buf.reserve(9);
        buf.extend(&[0xF2, 0x44, 0x0F, 0x10, 0x05 + (dst_mod << 3)]);
    } else {
        buf.reserve(8);
        buf.extend(&[0xF2, 0x0F, 0x10, 0x05 + (dst_mod << 3)]);
    }
    buf.extend(&offset.to_le_bytes());
}

/// `NEG r/m64` -> Two's complement negate r/m64.
#[inline(always)]
fn neg_reg64(buf: &mut Vec<'_, u8>, reg: X86_64GeneralReg) {
    let rex = add_rm_extension(reg, REX_W);
    let reg_mod = reg as u8 % 8;
    buf.extend(&[rex, 0xF7, 0xD8 + reg_mod]);
}

/// `SETE r/m64` -> Set Byte on Condition - zero/equal (ZF=1)
#[inline(always)]
fn sete_reg64(buf: &mut Vec<'_, u8>, reg: X86_64GeneralReg) {
    // XOR needs 3 bytes, actual SETE instruction need 3 or 4 bytes
    buf.reserve(7);

    // We reset reg to 0 because the SETE instruction only applies
    // to the lower bits of the register
    xor_reg64_reg64(buf, reg, reg);

    // Actually apply the SETE instruction
    let reg_mod = reg as u8 % 8;
    use X86_64GeneralReg::*;
    match reg {
        RAX | RCX | RDX | RBX => buf.extend(&[0x0F, 0x94, 0xC0 + reg_mod]),
        RSP | RBP | RSI | RDI => buf.extend(&[REX, 0x0F, 0x94, 0xC0 + reg_mod]),
        R8 | R9 | R10 | R11 | R12 | R13 | R14 | R15 => {
            buf.extend(&[REX + 1, 0x0F, 0x94, 0xC0 + reg_mod])
        }
    }
}

/// `RET` -> Near return to calling procedure.
#[inline(always)]
fn ret(buf: &mut Vec<'_, u8>) {
    buf.push(0xC3);
}

/// `SUB r/m64, imm32` -> Subtract imm32 sign-extended to 64-bits from r/m64.
#[inline(always)]
fn sub_reg64_imm32(buf: &mut Vec<'_, u8>, dst: X86_64GeneralReg, imm: i32) {
    // This can be optimized if the immediate is 1 byte.
    let rex = add_rm_extension(dst, REX_W);
    let dst_mod = dst as u8 % 8;
    buf.reserve(7);
    buf.extend(&[rex, 0x81, 0xE8 + dst_mod]);
    buf.extend(&imm.to_le_bytes());
}

/// `POP r64` -> Pop top of stack into r64; increment stack pointer. Cannot encode 32-bit operand size.
#[inline(always)]
fn pop_reg64(buf: &mut Vec<'_, u8>, reg: X86_64GeneralReg) {
    let reg_mod = reg as u8 % 8;
    if reg as u8 > 7 {
        let rex = add_opcode_extension(reg, REX);
        buf.extend(&[rex, 0x58 + reg_mod]);
    } else {
        buf.push(0x58 + reg_mod);
    }
}

/// `PUSH r64` -> Push r64,
#[inline(always)]
fn push_reg64(buf: &mut Vec<'_, u8>, reg: X86_64GeneralReg) {
    let reg_mod = reg as u8 % 8;
    if reg as u8 > 7 {
        let rex = add_opcode_extension(reg, REX);
        buf.extend(&[rex, 0x50 + reg_mod]);
    } else {
        buf.push(0x50 + reg_mod);
    }
}

// When writing tests, it is a good idea to test both a number and unnumbered register.
// This is because R8-R15 often have special instruction prefixes.
#[cfg(test)]
mod tests {
    use super::*;

    const TEST_I32: i32 = 0x12345678;
    const TEST_I64: i64 = 0x1234_5678_9ABC_DEF0;

    #[test]
    fn test_add_reg64_imm32() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for (dst, expected) in &[
            (X86_64GeneralReg::RAX, [0x48, 0x81, 0xC0]),
            (X86_64GeneralReg::R15, [0x49, 0x81, 0xC7]),
        ] {
            buf.clear();
            add_reg64_imm32(&mut buf, *dst, TEST_I32);
            assert_eq!(expected, &buf[..3]);
            assert_eq!(TEST_I32.to_le_bytes(), &buf[3..]);
        }
    }

    #[test]
    fn test_add_reg64_reg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for ((dst, src), expected) in &[
            (
                (X86_64GeneralReg::RAX, X86_64GeneralReg::RAX),
                [0x48, 0x01, 0xC0],
            ),
            (
                (X86_64GeneralReg::RAX, X86_64GeneralReg::R15),
                [0x4C, 0x01, 0xF8],
            ),
            (
                (X86_64GeneralReg::R15, X86_64GeneralReg::RAX),
                [0x49, 0x01, 0xC7],
            ),
            (
                (X86_64GeneralReg::R15, X86_64GeneralReg::R15),
                [0x4D, 0x01, 0xFF],
            ),
        ] {
            buf.clear();
            add_reg64_reg64(&mut buf, *dst, *src);
            assert_eq!(expected, &buf[..]);
        }
    }

    #[test]
    fn test_addsd_freg64_freg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for ((dst, src), expected) in &[
            (
                (X86_64FloatReg::XMM0, X86_64FloatReg::XMM0),
                vec![0xF2, 0x0F, 0x58, 0xC0],
            ),
            (
                (X86_64FloatReg::XMM0, X86_64FloatReg::XMM15),
                vec![0xF2, 0x41, 0x0F, 0x58, 0xC7],
            ),
            (
                (X86_64FloatReg::XMM15, X86_64FloatReg::XMM0),
                vec![0xF2, 0x44, 0x0F, 0x58, 0xF8],
            ),
            (
                (X86_64FloatReg::XMM15, X86_64FloatReg::XMM15),
                vec![0xF2, 0x45, 0x0F, 0x58, 0xFF],
            ),
        ] {
            buf.clear();
            addsd_freg64_freg64(&mut buf, *dst, *src);
            assert_eq!(&expected[..], &buf[..]);
        }
    }

    #[test]
    fn test_xor_reg64_reg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for ((dst, src), expected) in &[
            (
                (X86_64GeneralReg::RAX, X86_64GeneralReg::RAX),
                [0x48, 0x31, 0xC0],
            ),
            (
                (X86_64GeneralReg::RAX, X86_64GeneralReg::R15),
                [0x4C, 0x31, 0xF8],
            ),
            (
                (X86_64GeneralReg::R15, X86_64GeneralReg::RAX),
                [0x49, 0x31, 0xC7],
            ),
            (
                (X86_64GeneralReg::R15, X86_64GeneralReg::R15),
                [0x4D, 0x31, 0xFF],
            ),
        ] {
            buf.clear();
            xor_reg64_reg64(&mut buf, *dst, *src);
            assert_eq!(expected, &buf[..]);
        }
    }

    #[test]
    fn test_cmovl_reg64_reg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for ((dst, src), expected) in &[
            (
                (X86_64GeneralReg::RAX, X86_64GeneralReg::RAX),
                [0x48, 0x0F, 0x4C, 0xC0],
            ),
            (
                (X86_64GeneralReg::RAX, X86_64GeneralReg::R15),
                [0x49, 0x0F, 0x4C, 0xC7],
            ),
            (
                (X86_64GeneralReg::R15, X86_64GeneralReg::RAX),
                [0x4C, 0x0F, 0x4C, 0xF8],
            ),
            (
                (X86_64GeneralReg::R15, X86_64GeneralReg::R15),
                [0x4D, 0x0F, 0x4C, 0xFF],
            ),
        ] {
            buf.clear();
            cmovl_reg64_reg64(&mut buf, *dst, *src);
            assert_eq!(expected, &buf[..]);
        }
    }

    #[test]
    fn test_mov_reg64_imm32() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for (dst, expected) in &[
            (X86_64GeneralReg::RAX, [0x48, 0xC7, 0xC0]),
            (X86_64GeneralReg::R15, [0x49, 0xC7, 0xC7]),
        ] {
            buf.clear();
            mov_reg64_imm32(&mut buf, *dst, TEST_I32);
            assert_eq!(expected, &buf[..3]);
            assert_eq!(TEST_I32.to_le_bytes(), &buf[3..]);
        }
    }

    #[test]
    fn test_mov_reg64_imm64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for (dst, expected) in &[
            (X86_64GeneralReg::RAX, [0x48, 0xB8]),
            (X86_64GeneralReg::R15, [0x49, 0xBF]),
        ] {
            buf.clear();
            mov_reg64_imm64(&mut buf, *dst, TEST_I64);
            assert_eq!(expected, &buf[..2]);
            assert_eq!(TEST_I64.to_le_bytes(), &buf[2..]);
        }
        for (dst, expected) in &[
            (X86_64GeneralReg::RAX, [0x48, 0xC7, 0xC0]),
            (X86_64GeneralReg::R15, [0x49, 0xC7, 0xC7]),
        ] {
            buf.clear();
            mov_reg64_imm64(&mut buf, *dst, TEST_I32 as i64);
            assert_eq!(expected, &buf[..3]);
            assert_eq!(TEST_I32.to_le_bytes(), &buf[3..]);
        }
    }

    #[test]
    fn test_mov_reg64_reg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for ((dst, src), expected) in &[
            (
                (X86_64GeneralReg::RAX, X86_64GeneralReg::RAX),
                [0x48, 0x89, 0xC0],
            ),
            (
                (X86_64GeneralReg::RAX, X86_64GeneralReg::R15),
                [0x4C, 0x89, 0xF8],
            ),
            (
                (X86_64GeneralReg::R15, X86_64GeneralReg::RAX),
                [0x49, 0x89, 0xC7],
            ),
            (
                (X86_64GeneralReg::R15, X86_64GeneralReg::R15),
                [0x4D, 0x89, 0xFF],
            ),
        ] {
            buf.clear();
            mov_reg64_reg64(&mut buf, *dst, *src);
            assert_eq!(expected, &buf[..]);
        }
    }

    #[test]
    fn test_mov_reg64_stack32() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for ((dst, offset), expected) in &[
            ((X86_64GeneralReg::RAX, TEST_I32), [0x48, 0x8B, 0x84, 0x24]),
            ((X86_64GeneralReg::R15, TEST_I32), [0x4C, 0x8B, 0xBC, 0x24]),
        ] {
            buf.clear();
            mov_reg64_stack32(&mut buf, *dst, *offset);
            assert_eq!(expected, &buf[..4]);
            assert_eq!(TEST_I32.to_le_bytes(), &buf[4..]);
        }
    }

    #[test]
    fn test_mov_stack32_reg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for ((offset, src), expected) in &[
            ((TEST_I32, X86_64GeneralReg::RAX), [0x48, 0x89, 0x84, 0x24]),
            ((TEST_I32, X86_64GeneralReg::R15), [0x4C, 0x89, 0xBC, 0x24]),
        ] {
            buf.clear();
            mov_stack32_reg64(&mut buf, *offset, *src);
            assert_eq!(expected, &buf[..4]);
            assert_eq!(TEST_I32.to_le_bytes(), &buf[4..]);
        }
    }

    #[test]
    fn test_movsd_freg64_freg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for ((dst, src), expected) in &[
            (
                (X86_64FloatReg::XMM0, X86_64FloatReg::XMM0),
                vec![0xF2, 0x0F, 0x10, 0xC0],
            ),
            (
                (X86_64FloatReg::XMM0, X86_64FloatReg::XMM15),
                vec![0xF2, 0x41, 0x0F, 0x10, 0xC7],
            ),
            (
                (X86_64FloatReg::XMM15, X86_64FloatReg::XMM0),
                vec![0xF2, 0x44, 0x0F, 0x10, 0xF8],
            ),
            (
                (X86_64FloatReg::XMM15, X86_64FloatReg::XMM15),
                vec![0xF2, 0x45, 0x0F, 0x10, 0xFF],
            ),
        ] {
            buf.clear();
            movsd_freg64_freg64(&mut buf, *dst, *src);
            assert_eq!(&expected[..], &buf[..]);
        }
    }

    #[test]
    fn test_movsd_freg64_rip_offset32() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for ((dst, offset), expected) in &[
            (
                (X86_64FloatReg::XMM0, TEST_I32),
                vec![0xF2, 0x0F, 0x10, 0x05],
            ),
            (
                (X86_64FloatReg::XMM15, TEST_I32),
                vec![0xF2, 0x44, 0x0F, 0x10, 0x3D],
            ),
        ] {
            buf.clear();
            movsd_freg64_rip_offset32(&mut buf, *dst, *offset as u32);
            assert_eq!(&expected[..], &buf[..(buf.len() - 4)]);
            assert_eq!(TEST_I32.to_le_bytes(), &buf[(buf.len() - 4)..]);
        }
    }

    #[test]
    fn test_neg_reg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for (reg, expected) in &[
            (X86_64GeneralReg::RAX, [0x48, 0xF7, 0xD8]),
            (X86_64GeneralReg::R15, [0x49, 0xF7, 0xDF]),
        ] {
            buf.clear();
            neg_reg64(&mut buf, *reg);
            assert_eq!(expected, &buf[..]);
        }
    }

    #[test]
    fn test_sete_reg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];

        // tests for 6 bytes in the output buffer
        let (reg, expected) = (
            X86_64GeneralReg::RAX,
            [
                0x48, 0x31, 0xC0, // XOR rax, rax
                0x0F, 0x94, 0xC0, // SETE al ; al are the 8 lower weight bits of rax
            ],
        );
        buf.clear();
        sete_reg64(&mut buf, reg);
        assert_eq!(expected, &buf[..]);

        // tests for 7 bytes in the output buffer
        for (reg, expected) in &[
            (
                X86_64GeneralReg::RSP,
                [
                    // XOR rsp, rsp
                    0x48, 0x31, 0xE4,
                    // SETE spl ; spl are the 8 lower weight bits of rsp
                    0x40, 0x0F, 0x94, 0xC4,
                ],
            ),
            (
                X86_64GeneralReg::R15,
                [
                    // XOR r15, r15
                    0x4D, 0x31, 0xFF,
                    // SETE r15b ; r15b are the 8 lower weight bits of r15
                    0x41, 0x0F, 0x94, 0xC7,
                ],
            ),
        ] {
            buf.clear();
            sete_reg64(&mut buf, *reg);
            assert_eq!(expected, &buf[..]);
        }
    }

    #[test]
    fn test_ret() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        ret(&mut buf);
        assert_eq!(&[0xC3], &buf[..]);
    }

    #[test]
    fn test_sub_reg64_imm32() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for (dst, expected) in &[
            (X86_64GeneralReg::RAX, [0x48, 0x81, 0xE8]),
            (X86_64GeneralReg::R15, [0x49, 0x81, 0xEF]),
        ] {
            buf.clear();
            sub_reg64_imm32(&mut buf, *dst, TEST_I32);
            assert_eq!(expected, &buf[..3]);
            assert_eq!(TEST_I32.to_le_bytes(), &buf[3..]);
        }
    }

    #[test]
    fn test_pop_reg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for (dst, expected) in &[
            (X86_64GeneralReg::RAX, vec![0x58]),
            (X86_64GeneralReg::R15, vec![0x41, 0x5F]),
        ] {
            buf.clear();
            pop_reg64(&mut buf, *dst);
            assert_eq!(&expected[..], &buf[..]);
        }
    }

    #[test]
    fn test_push_reg64() {
        let arena = bumpalo::Bump::new();
        let mut buf = bumpalo::vec![in &arena];
        for (src, expected) in &[
            (X86_64GeneralReg::RAX, vec![0x50]),
            (X86_64GeneralReg::R15, vec![0x41, 0x57]),
        ] {
            buf.clear();
            push_reg64(&mut buf, *src);
            assert_eq!(&expected[..], &buf[..]);
        }
    }
}

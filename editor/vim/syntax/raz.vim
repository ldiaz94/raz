" Vim syntax file for raz: reserved words, basic types, built-in
" procedures, numbers, characters, strings and nested comments.

if exists("b:current_syntax")
  finish
endif

syntax case match

syntax keyword razKeyword and begin break by code const defer div do else
syntax keyword razKeyword elsif end extern for forward if import in link
syntax keyword razKeyword match mod module not of or packed proc record
syntax keyword razKeyword repeat return set shl shr then to type until var
syntax keyword razKeyword variant VOLATILE while xor
syntax keyword razType I8 I16 I32 I64 U8 U16 U32 U64 BOOL F32 F64 ERROR
syntax keyword razBuiltin SIZE ADR LEN NEW MSG SYSCALL FENCE CAS XCHG XADD
syntax keyword razBuiltin ARGC ARGV INC DEC
syntax keyword razConstant true false nil

" 123, 0FFH, 1.5, 2.0E-3
syntax match razNumber "\<\d[0-9A-F]*H\>"
syntax match razNumber "\<\d\+\>"
syntax match razNumber "\<\d\+\.\d\+\(E[+-]\=\d\+\)\=\>"

syntax match razEscape contained "\\\([ntr0\\'\"]\|x\x\x\|u{\x\+}\)"
syntax region razString start=+"+ skip=+\\.+ end=+"+ contains=razEscape oneline
syntax region razChar start=+'+ skip=+\\.+ end=+'+ contains=razEscape oneline

syntax region razComment start="(\*" end="\*)" contains=razComment,@Spell
syntax sync fromstart

highlight default link razKeyword Statement
highlight default link razType Type
highlight default link razBuiltin Function
highlight default link razConstant Constant
highlight default link razNumber Number
highlight default link razString String
highlight default link razChar Character
highlight default link razEscape SpecialChar
highlight default link razComment Comment

let b:current_syntax = "raz"

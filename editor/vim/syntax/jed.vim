" Vim syntax file for jed: reserved words, basic types, built-in
" procedures, numbers, characters, strings and nested comments.

if exists("b:current_syntax")
  finish
endif

syntax case match

syntax keyword jedKeyword and begin break by code const defer div do else
syntax keyword jedKeyword elsif end extern for forward if import in link
syntax keyword jedKeyword match mod module not of or packed proc record
syntax keyword jedKeyword repeat return set shl shr then to type until var
syntax keyword jedKeyword variant VOLATILE while xor
syntax keyword jedType I8 I16 I32 I64 U8 U16 U32 U64 BOOL F32 F64 ERROR
syntax keyword jedBuiltin SIZE ADR LEN NEW MSG SYSCALL FENCE CAS XCHG XADD
syntax keyword jedBuiltin ARGC ARGV INC DEC
syntax keyword jedConstant true false nil

" 123, 0FFH, 1.5, 2.0E-3
syntax match jedNumber "\<\d[0-9A-F]*H\>"
syntax match jedNumber "\<\d\+\>"
syntax match jedNumber "\<\d\+\.\d\+\(E[+-]\=\d\+\)\=\>"

syntax match jedEscape contained "\\\([ntr0\\'\"]\|x\x\x\|u{\x\+}\)"
syntax region jedString start=+"+ skip=+\\.+ end=+"+ contains=jedEscape oneline
syntax region jedChar start=+'+ skip=+\\.+ end=+'+ contains=jedEscape oneline

syntax region jedComment start="(\*" end="\*)" contains=jedComment,@Spell
syntax sync fromstart

highlight default link jedKeyword Statement
highlight default link jedType Type
highlight default link jedBuiltin Function
highlight default link jedConstant Constant
highlight default link jedNumber Number
highlight default link jedString String
highlight default link jedChar Character
highlight default link jedEscape SpecialChar
highlight default link jedComment Comment

let b:current_syntax = "jed"

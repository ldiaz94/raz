" Vim indent file for raz, by shiftwidth(): a block's statements one
" level in from the word that opens it; end, until, else and elsif at
" that word's level; match arms at the level of match; procedures,
" sections (const, type, var) and module bodies at the left margin.
" The text of a comment, and a line that goes on with the expression
" of the line before, keep the indent they have.

if exists("b:did_indent")
  finish
endif
let b:did_indent = 1

setlocal indentexpr=GetRazIndent(v:lnum)
setlocal indentkeys=o,O,0=end,0=else,0=elsif,0=until,0=\|,!^F
setlocal nolisp nosmartindent

if exists("*GetRazIndent")
  finish
endif

" searchpair() needs groups that don't capture
let s:opener = '\C\<\%(if\|while\|for\|match\|record\|variant\|begin\|repeat\|code\)\>'
let s:closer = '\C\<\%(end\|until\)\>'
let s:skip = 'synIDattr(synID(line("."), col("."), 1), "name") =~? "string\\|char\\|comment"'
let s:decl = '^\s*\%(module\|import\|link\|extern\|proc\|const\|type\|var\|begin\|code\)\>'

" The line's code, without strings, characters and comments.
function! s:Code(lnum)
  let line = getline(a:lnum)
  " a line that starts inside a comment: its code is after the comment
  if s:InComment(a:lnum)
    let line = line =~ '\*)' ? substitute(line, '^.\{-}\*)', '', '') : ''
  endif
  " one pattern, so that whichever comes first is taken: a " in a
  " character, a ' in a string; strings become 0, comments go
  let line = substitute(line,
        \ '"\%([^"\\]\|\\.\)*"\|''\%([^''\\]\|\\.\)*''\|(\*.\{-}\*)',
        \ '\=submatch(0)[0] == "(" ? "" : "0"', 'g')
  let line = substitute(line, '(\*.*$', '', '')
  return substitute(line, '^\s*\(.\{-}\)\s*$', '\1', '')
endfunction

" Whether the expression on lnum goes on to the next line.
function! s:Continues(lnum)
  let code = s:Code(a:lnum)
  if len(substitute(code, '[^([{]', '', 'g')) > len(substitute(code, '[^)\]}]', '', 'g'))
    return 1
  endif
  return code =~# '\%(,\|:=\|[-+*/&|=#<>]\|\<and\|\<or\)$'
endfunction

let s:leading = '^\s*\%(or\|and\)\>'

" The first line of the statement that ends on lnum.
function! s:Start(lnum)
  let l = a:lnum
  while 1
    let p = prevnonblank(l - 1)
    if p == 0 || !s:Continues(p) && getline(l) !~# s:leading
      return l
    endif
    let l = p
  endwhile
endfunction

" The line itself, or where the comment it ends began, if it holds
" nothing but comment.
function! s:Reference(lnum)
  let l = a:lnum
  if s:Code(l) != ''
    return l
  endif
  while l > 1 && getline(l) !~ '(\*'
    let l -= 1
  endwhile
  return l
endfunction

" How many blocks the code opens, less those it closes.
function! s:Opens(code)
  let n = 0
  let i = 0
  while 1
    let m = matchstrpos(a:code, '\C\<\%(if\|while\|for\|record\|variant\|begin\|repeat\|code\|end\|until\)\>', i)
    if m[1] < 0
      return n
    endif
    let n += (m[0] ==# 'end' || m[0] ==# 'until') ? -1 : 1
    let i = m[2]
  endwhile
endfunction

function! s:InComment(lnum)
  let col = match(getline(a:lnum), '\S') + 1
  return col > 0 && synIDattr(synID(a:lnum, col, 1), "name") =~? 'comment'
        \ && getline(a:lnum) !~ '^\s*(\*'
endfunction

function! GetRazIndent(lnum)
  let cur = getline(a:lnum)
  if s:InComment(a:lnum)
    return -1
  endif
  if cur =~# s:decl && cur !~# '^\s*proc\s*('
    return 0
  endif
  " a comment before a declaration goes with it, at the margin
  if cur =~ '^\s*(\*'
    let l = a:lnum
    while l < line('$') && getline(l) !~ '\*)'
      let l += 1
    endwhile
    if getline(nextnonblank(l + 1)) =~# s:decl
      return 0
    endif
  endif
  if cur =~# '^\s*\%(end\|until\)\>'
    call cursor(a:lnum, 1)
    let l = searchpair(s:opener, '', s:closer, 'bW', s:skip)
    return l > 0 ? indent(l) : 0
  endif
  let prev = prevnonblank(a:lnum - 1)
  if prev == 0
    return 0
  endif
  if cur =~# '^\s*\%(else\|elsif\)\>'
    call cursor(a:lnum, 1)
    let l = searchpair(s:opener, '', s:closer, 'bW', s:skip)
    return l > 0 ? indent(l) : indent(prev)
  endif
  if cur =~# '^\s*|'
    call cursor(a:lnum, 1)
    let l = searchpair(s:opener, '', s:closer, 'bW', s:skip)
    return l > 0 ? indent(l) : indent(prev)
  endif
  if s:Continues(prev) || cur =~# s:leading
    return -1
  endif
  if s:Code(prev) == ''
    return indent(s:Reference(prev))
  endif

  let start = s:Start(prev)
  let ind = indent(start)
  let code = join(map(range(start, prev), 's:Code(v:val)'), ' ')
  if code =~# '^\%(const\|type\|var\)$' || code =~# '^else\>' && s:Opens(code) >= 0
        \ || code =~# '^|.*:$' || code =~# '^elsif\>.*\<then$'
    return ind + shiftwidth()
  endif
  if code =~# '^|' || code =~# '\<match\>.*\<of$'
    return ind
  endif
  if s:Opens(code) > 0
    return ind + shiftwidth()
  endif
  return ind
endfunction

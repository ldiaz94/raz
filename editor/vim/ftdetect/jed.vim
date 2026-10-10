" jed: *.jed files, indented by 4 spaces.
autocmd BufRead,BufNewFile *.jed setfiletype jed
autocmd FileType jed setlocal shiftwidth=4 softtabstop=4 expandtab

" raz: *.raz files, indented by 4 spaces.
autocmd BufRead,BufNewFile *.raz setfiletype raz
autocmd FileType raz setlocal shiftwidth=4 softtabstop=4 expandtab

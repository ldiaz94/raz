#!/bin/sh
# Loads the editor support, headless, on each example: the file must be
# taken for raz, coloured without error, and indented again exactly as
# it is written; and test/editors/Colours.raz must be coloured as
# Colours.expect says. Prints one line per failure; quiet if the editor
# is missing.

fail=0
if command -v vim >/dev/null; then
    for f in examples/*.raz; do
        vim -Nu NONE -i NONE -es \
            -c 'set rtp^=editor/vim' -c 'filetype plugin indent on' -c 'syntax on' \
            -c "edit $f" \
            -c 'if &filetype !=# "raz" || &shiftwidth != 4 | cquit | endif' \
            -c 'let before = getline(1, "$")' -c 'normal! gg=G' \
            -c 'if getline(1, "$") != before | cquit | endif' -c 'qall!' \
            || { echo "FAIL vim on $f"; fail=1; }
    done
    vim -Nu NONE -i NONE -es -c 'set rtp^=editor/vim' -c 'filetype plugin indent on' \
        -c 'syntax on' -c 'edit test/editors/Colours.raz' -S test/editors/colours.vim \
        || { echo "FAIL vim colours"; fail=1; }
fi
if command -v emacs >/dev/null; then
    for f in examples/*.raz; do
        emacs -Q --batch -l editor/emacs/raz-mode.el --eval "
          (progn
            (find-file \"$f\")
            (unless (eq major-mode 'raz-mode) (kill-emacs 1))
            (font-lock-ensure)
            (let ((before (buffer-string)))
              (indent-region (point-min) (point-max))
              (unless (string= before (buffer-string)) (kill-emacs 2))))" \
            2>/dev/null || { echo "FAIL emacs on $f"; fail=1; }
    done
    emacs -Q --batch -l editor/emacs/raz-mode.el -l test/editors/colours.el 2>/dev/null \
        || { echo "FAIL emacs colours"; fail=1; }
fi
exit $fail

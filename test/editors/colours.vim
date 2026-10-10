" Checks each token of Colours.expect has the colour group it should.
let s:kinds = {'razComment': 'comment', 'razKeyword': 'keyword', 'razNumber': 'number',
      \ 'razString': 'string', 'razChar': 'string', 'razType': 'type',
      \ 'razBuiltin': 'builtin', 'razConstant': 'constant'}
for s:want in readfile('test/editors/Colours.expect')
  let [s:l, s:c, s:k] = split(s:want)
  let s:group = synIDattr(synID(str2nr(s:l), str2nr(s:c), 1), 'name')
  if get(s:kinds, s:group, '') !=# s:k
    cquit
  endif
endfor
qall!

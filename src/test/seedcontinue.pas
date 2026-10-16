{ The seed has no continue, which report 2026-10.31 made a reserved
  word, the last of them in src/Scan.raz. This unit interns the name
  right after the seed's reserved words, before any other, so that
  every name after it has the number src/ gives it: each dumper that is
  compared with src/'s side uses it straight after scan. }
unit seedcontinue;

{$mode objfpc}{$H-}

interface

implementation

uses scan;

const Word: string = 'continue';

initialization
  Intern(@Word[1], length(Word));
end.

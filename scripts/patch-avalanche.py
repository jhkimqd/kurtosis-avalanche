import pathlib, sys
p = pathlib.Path(sys.argv[1]) / 'ids/id.go'
old = 'func (id *ID) UnmarshalText(text []byte) error {\n\treturn id.UnmarshalJSON(text)\n}'
new = '''func (id *ID) UnmarshalText(text []byte) error {
 parsed, err := FromString(string(text))
 if err != nil { return err }
 *id = parsed
 return nil
}'''
s = p.read_text()
if old in s:
    p.write_text(s.replace(old, new, 1))
elif new not in s:
    raise SystemExit('Unexpected upstream ID decoder; refusing an unverified patch')

// Models often omit outer whitespace in plain-text responses. Restore only
// application-owned outer frame whitespace; never trim the editable region or
// repair other changes to read-only text. Raw model responses remain on disk.
export function restoreOuterFrame(text, scope) {
  if (typeof text !== 'string' || !scope) return {text, restored:false};
  const raw = text;
  const leading = scope.before.match(/^[ \t\r\n]*/)[0];
  const prefix = scope.before.slice(leading.length);
  if (prefix.length) {
    const body = text.replace(/^[ \t\r\n]*/, '');
    if (body.startsWith(prefix)) text = leading + body;
  } else if (leading && !/^[ \t\r\n]/.test(text)) {
    text = leading + text;
  }
  const trailing = scope.after.match(/[ \t\r\n]*$/)[0];
  const suffix = scope.after.slice(0, scope.after.length - trailing.length);
  if (suffix.length) {
    const body = text.replace(/[ \t\r\n]*$/, '');
    if (body.endsWith(suffix)) text = body + trailing;
  } else if (trailing && !/[ \t\r\n]$/.test(text)) {
    text += trailing;
  }
  return {text, restored:text !== raw};
}

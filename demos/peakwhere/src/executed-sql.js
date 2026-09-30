// Show the SQL captured by the session, without regenerating any analysis query.
export function mountExecutedSql(root, sqlConsole) {
  const pre = root.querySelector("pre");
  root.querySelector('[data-action="copy"]').addEventListener("click", () =>
    navigator.clipboard.writeText(pre.textContent));
  root.querySelector('[data-action="open"]').addEventListener("click", () =>
    sqlConsole.load(pre.textContent));
  return (statements) => {
    root.open = false;
    pre.textContent = statements.join("\n;\n");
  };
}

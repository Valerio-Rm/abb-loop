import re
from pathlib import Path


def strip_line_comments(s: str) -> str:
    out_lines = []
    for line in s.splitlines(True):
        i = 0
        in_str = False
        res = []
        while i < len(line):
            ch = line[i]
            if ch == "'":
                if in_str and i + 1 < len(line) and line[i + 1] == "'":
                    res.append("''")
                    i += 2
                    continue
                in_str = not in_str
                res.append(ch)
                i += 1
                continue
            if (not in_str) and ch == "-" and i + 1 < len(line) and line[i + 1] == "-":
                break
            res.append(ch)
            i += 1
        out_lines.append("".join(res))
    return "".join(out_lines)


def split_top_level_commas(s: str) -> list[str]:
    parts = []
    buf = []
    depth = 0
    in_str = False
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == "'":
            if in_str and i + 1 < len(s) and s[i + 1] == "'":
                buf.append("''")
                i += 2
                continue
            in_str = not in_str
            buf.append(ch)
            i += 1
            continue
        if not in_str:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth = max(0, depth - 1)
            elif ch == "," and depth == 0:
                parts.append("".join(buf).strip())
                buf = []
                i += 1
                continue
        buf.append(ch)
        i += 1
    if buf:
        parts.append("".join(buf).strip())
    return parts


_string_lit_re = re.compile(r"'((?:''|[^'])*)'")


def extract_string_literals(expr: str) -> list[str]:
    return [m.group(1).replace("''", "'") for m in _string_lit_re.finditer(expr)]


def mask_from_concat(expr: str) -> str:
    parts = []
    buf = []
    depth = 0
    in_str = False
    i = 0
    while i < len(expr):
        ch = expr[i]
        if ch == "'":
            if in_str and i + 1 < len(expr) and expr[i + 1] == "'":
                buf.append("''")
                i += 2
                continue
            in_str = not in_str
            buf.append(ch)
            i += 1
            continue
        if not in_str:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth = max(0, depth - 1)
            if ch == "|" and i + 1 < len(expr) and expr[i + 1] == "|" and depth == 0:
                parts.append("".join(buf).strip())
                buf = []
                i += 2
                continue
        buf.append(ch)
        i += 1
    if buf:
        parts.append("".join(buf).strip())

    out = []
    for p in parts:
        lits = extract_string_literals(p)
        if lits and p.strip().startswith("'") and p.strip().endswith("'") and len(lits) == 1:
            out.append(lits[0])
        else:
            out.append("****")
    res = "".join(out)
    res = re.sub(r"\*{4,}", "****", res)
    return res


def mask_from_template(tmpl: str) -> str:
    s = tmpl.replace("%%", "%")
    s = re.sub(r"%[sIL]", "****", s)
    s = re.sub(r"%", "****", s)
    s = re.sub(r"\*{4,}", "****", s)
    return s


def classify(expr: str) -> tuple[str, str]:
    e = expr.strip()
    lits = extract_string_literals(e)
    if len(lits) == 1 and e == ("'" + lits[0].replace("'", "''") + "'"):
        return "static", lits[0]

    m = re.search(r"\bformat\s*\(\s*('(?:''|[^'])*')\s*,", e, flags=re.IGNORECASE)
    if m:
        tmpl_lits = extract_string_literals(m.group(1))
        tmpl = tmpl_lits[0] if tmpl_lits else ""
        return "variable", mask_from_template(tmpl)

    if "||" in e:
        return "variable", mask_from_concat(e)

    if "%" in e and lits:
        return "variable", mask_from_template(lits[0])

    if lits:
        return "variable", mask_from_template(lits[0])

    return "variable", "****"


def norm_field(s: str) -> str:
    s = " ".join(s.replace("\r", " ").replace("\n", " ").split())
    return s


def quote_field(s: str) -> str:
    return '"' + s.replace('"', '""') + '"'


def split_top_level_semicolons(s: str) -> list[str]:
    parts = []
    buf = []
    depth = 0
    in_str = False
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == "'":
            if in_str and i + 1 < len(s) and s[i + 1] == "'":
                buf.append("''")
                i += 2
                continue
            in_str = not in_str
            buf.append(ch)
            i += 1
            continue
        if not in_str:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth = max(0, depth - 1)
            elif ch == ";" and depth == 0:
                stmt = "".join(buf).strip()
                if stmt:
                    parts.append(stmt)
                buf = []
                i += 1
                continue
        buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        parts.append(tail)
    return parts


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    sql_path = root / "4_create_function_procedure.sql"
    out_path = root / "Procedure exception msg.csv"

    text = sql_path.read_text(encoding="utf-8", errors="replace")
    clean = strip_line_comments(text)

    proc_re = re.compile(r"\bCREATE\s+OR\s+REPLACE\s+PROCEDURE\s+([^\s(]+)", re.IGNORECASE)
    procs = [(m.start(), m.group(1)) for m in proc_re.finditer(clean)]
    procs.sort()

    ranges: list[tuple[str, str]] = []
    for idx, (start, name) in enumerate(procs):
        end = procs[idx + 1][0] if idx + 1 < len(procs) else len(clean)
        ranges.append((name, clean[start:end]))

    raise_re = re.compile(r"\bRAISE\s+EXCEPTION\b(.*)$", re.IGNORECASE | re.DOTALL)
    call_log_re = re.compile(r"\bCALL\s+application_data\.log_error_write\s*\((.*?)\)\s*$", re.IGNORECASE | re.DOTALL)
    insert_log_re = re.compile(
        r"INSERT\s+INTO\s+application_data\.log_error\b.*?VALUES\s*\((.*?)\)\s*$",
        re.IGNORECASE | re.DOTALL,
    )

    rows: list[tuple[str, str, str, str]] = []
    for proc, block in ranges:
        msg_vars = {"msg", "lp_err_msg", "err_msg", "lp_error_msg"}
        current_assign: dict[str, str] = {}

        for stmt in split_top_level_semicolons(block):
            # Update assignment map first (so subsequent statements see it).
            # Assignment may appear after control keywords (e.g. WHEN ... THEN msg := ...).
            for m_assign in re.finditer(
                r"\b([a-zA-Z_][a-zA-Z0-9_]*)\s*:?=\s*(.+)\s*$",
                stmt,
                flags=re.DOTALL,
            ):
                var = m_assign.group(1)
                if var in msg_vars:
                    current_assign[var] = m_assign.group(2).strip()

            # Capture INSERT INTO application_data.log_error ... VALUES (...)
            m_ins = insert_log_re.search(stmt)
            if m_ins:
                vals = split_top_level_commas(m_ins.group(1))
                if len(vals) >= 3:
                    msg_expr = vals[2].strip()
                    msg_expr = current_assign.get(msg_expr, msg_expr)
                    if msg_expr in msg_vars:
                        continue
                    typ, mask = classify(msg_expr)
                    rows.append((proc, msg_expr, typ, mask))
                continue

            # Capture CALL log_error_write(...)
            m_call = call_log_re.search(stmt)
            if m_call:
                parts = split_top_level_commas(m_call.group(1).strip())
                if len(parts) >= 2:
                    msg_expr = parts[1].strip()
                    msg_expr = current_assign.get(msg_expr, msg_expr)
                    if msg_expr in msg_vars:
                        continue
                    typ, mask = classify(msg_expr)
                    rows.append((proc, msg_expr, typ, mask))
                continue

            # Capture RAISE EXCEPTION ...
            m_raise = raise_re.search(stmt)
            if m_raise:
                expr = m_raise.group(1).strip()
                mapped_expr = expr
                m_pct = re.match(
                    r"^'%'\s*,\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*(?:USING\b.*)?$",
                    expr,
                    flags=re.IGNORECASE | re.DOTALL,
                )
                if m_pct:
                    v = m_pct.group(1)
                    mapped_expr = current_assign.get(v, mapped_expr)
                elif expr in current_assign:
                    mapped_expr = current_assign[expr]

                if mapped_expr in msg_vars:
                    continue

                typ, mask = classify(mapped_expr)
                rows.append((proc, f"RAISE EXCEPTION {expr}" if expr == mapped_expr else mapped_expr, typ, mask))

    seen: set[tuple[str, str]] = set()
    dedup: list[tuple[str, str, str, str]] = []
    for r in rows:
        key = (r[0], r[1])
        if key in seen:
            continue
        seen.add(key)
        dedup.append(r)

    lines = ["procedure|error_message_full|type|static_mask"]
    for proc, expr, typ, mask in dedup:
        lines.append(
            "|".join(
                [
                    quote_field(norm_field(proc)),
                    quote_field(norm_field(expr)),
                    quote_field(typ),
                    quote_field(norm_field(mask)),
                ]
            )
        )

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {len(dedup)} rows -> {out_path}")


if __name__ == "__main__":
    main()


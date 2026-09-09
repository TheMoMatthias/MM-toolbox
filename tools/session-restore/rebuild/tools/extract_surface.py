# Extract the tool's CAPABILITY SURFACE from source: every control the operator
# can reach, what it says it does, and what it calls.
#
# WHY IT IS EXTRACTED RATHER THAN LISTED. A feature list written from memory is
# a list of the features somebody remembered. This one is every x:Name in the
# XAML joined to every handler wired to it in the window script, so a control
# that exists but was forgotten still appears - and a control that is WIRED TO
# NOTHING appears too, which is worth knowing before rebuilding it.
#
# The ToolTip text is the operator-facing description of each control, written
# at the time it was built. It is the closest thing this repo has to a
# requirements document, so it is carried through verbatim.
#
# Usage:  python rebuild/tools/extract_surface.py
# Writes: rebuild/01-CAPABILITIES.md, rebuild/surface.json
import io, os, re, json

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
OUT = os.path.join(ROOT, 'rebuild')

XAML = os.path.join(ROOT, 'lib', 'window2.xaml')
WIN = os.path.join(ROOT, 'lib', 'sessions-window.ps1')


def xaml_elements():
    """Every named element: its tag, its Content/Text, and its ToolTip."""
    src = io.open(XAML, encoding='utf-8').read()
    out = {}
    # An element runs from its '<' to the matching '>' of the opening tag.
    for m in re.finditer(r'<([A-Za-z:][\w:.]*)\b((?:[^<>\'"]|"[^"]*"|\'[^\']*\')*?)/?>', src, re.S):
        tag, attrs = m.group(1), m.group(2)
        nm = re.search(r'x:Name="([^"]+)"', attrs)
        if not nm:
            continue
        line = src.count('\n', 0, m.start()) + 1

        def attr(name):
            a = re.search(r'\b%s="([^"]*)"' % name, attrs)
            return a.group(1) if a else ''
        out[nm.group(1)] = {
            'name': nm.group(1),
            'tag': tag.split(':')[-1],
            'line': line,
            'content': attr('Content') or attr('Text'),
            'tooltip': attr('ToolTip'),
            'automation': attr('AutomationProperties.Name'),
        }
    # ToolTips written as an element rather than an attribute.
    for m in re.finditer(r'x:Name="([^"]+)"[^>]*?>\s*<[\w:.]*\.ToolTip>\s*<[^>]*?(?:Text|Content)="([^"]*)"', src, re.S):
        if m.group(1) in out and not out[m.group(1)]['tooltip']:
            out[m.group(1)]['tooltip'] = m.group(2)
    return out


def balanced(src, start):
    """From the '{' at start, the index just past its matching '}'."""
    d = 0
    i = start
    n = len(src)
    while i < n:
        c = src[i]
        if c == '{':
            d += 1
        elif c == '}':
            d -= 1
            if d == 0:
                return i + 1
        elif c == "'":
            i = src.find("'", i + 1)
            if i < 0:
                return n
        elif c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == '`' else 1
            i = j
        i += 1
    return n


KNOWN_VERBS = re.compile(r'\b((?:Get|Set|New|Show|Hide|Build|Update|Start|Stop|Send|Save|Invoke|Test|Step|Open|Close|Toggle|Add|Remove|Complete|Merge|Sync|Limit|Move|Expand|Fill|Draw|Read|Write|Clear|Pick|Apply|Copy|Restore|Shelve|Relaunch|Interrupt|Compact)-[A-Z][\w]*)\b')


def handlers():
    src = io.open(WIN, encoding='utf-8').read()
    out = []
    for m in re.finditer(r'\$ui\.([A-Za-z0-9_]+)\.(Add_[A-Za-z]+)\(\s*\{', src):
        body_start = src.index('{', m.end() - 1)
        body = src[body_start:balanced(src, body_start)]
        line = src.count('\n', 0, m.start()) + 1
        calls = sorted(set(KNOWN_VERBS.findall(body)))
        out.append({
            'element': m.group(1),
            'event': m.group(2)[4:],
            'line': line,
            'calls': calls,
            'size': body.count('\n') + 1,
        })
    return out


def menu_items():
    """Right-click menu entries, built by the local `& $mk 'Label' { ... }` idiom."""
    src = io.open(WIN, encoding='utf-8').read()
    out = []
    for m in re.finditer(r"\$mk\s+'([^']+)'\s*\{", src):
        body_start = src.index('{', m.end() - 1)
        body = src[body_start:balanced(src, body_start)]
        out.append({
            'label': m.group(1),
            'line': src.count('\n', 0, m.start()) + 1,
            'calls': sorted(set(KNOWN_VERBS.findall(body))),
        })
    return out


def timers():
    src = io.open(WIN, encoding='utf-8').read()
    out = []
    for m in re.finditer(r'\$script:(\w+)\s*=\s*New-Object System\.Windows\.Threading\.DispatcherTimer', src):
        nm = m.group(1)
        iv = re.search(r'\$script:%s\.Interval\s*=\s*([^\r\n]+)' % re.escape(nm), src)
        out.append({
            'name': nm,
            'line': src.count('\n', 0, m.start()) + 1,
            'interval': iv.group(1).strip() if iv else '(set elsewhere)',
        })
    return out


def cadences():
    """The named intervals and budgets - the numbers that decide how live it feels."""
    src = io.open(WIN, encoding='utf-8').read()
    out = []
    for m in re.finditer(r'^\$(SR_\w*(?:Every|Ms|Max|Back|Seconds|Base)\w*|script:(?:Fast|Live)Seconds)\s*=\s*([^\r\n#]+)',
                         src, re.M):
        out.append({'name': m.group(1), 'value': m.group(2).strip(),
                    'line': src.count('\n', 0, m.start()) + 1})
    return out


def shortcuts():
    src = io.open(WIN, encoding='utf-8').read()
    out = []
    blob = src[src.rindex('$window.Add_PreviewKeyDown'):]
    for m in re.finditer(r"\$e\.Key\s+-eq\s+'([A-Za-z0-9]+)'", blob):
        out.append(m.group(1))
    seen = []
    for k in out:
        if k not in seen:
            seen.append(k)
    return seen


def main():
    els = xaml_elements()
    hs = handlers()
    wired = {}
    for h in hs:
        wired.setdefault(h['element'], []).append(h)

    md = []
    md.append('# The capability surface')
    md.append('')
    md.append('**Generated by `rebuild/tools/extract_surface.py` - do not edit by hand.**')
    md.append('')
    md.append('Every named control in `lib/window2.xaml`, joined to every handler wired to')
    md.append('it in `lib/sessions-window.ps1`. The ToolTip column is what the tool tells')
    md.append('the operator the control does, written when it was built - it is the closest')
    md.append('thing here to a requirements document, so it is carried through verbatim.')
    md.append('')
    md.append('- **%d** named elements in the XAML' % len(els))
    md.append('- **%d** wired handlers across **%d** of them' % (len(hs), len(wired)))
    md.append('- **%d** named elements have NO handler (layout, labels, or dead)' % (len(els) - len(wired)))
    md.append('')

    md.append('## Controls that do something')
    md.append('')
    md.append('| control | kind | says | events | calls |')
    md.append('|---|---|---|---|---|')
    for nm in sorted(wired.keys()):
        e = els.get(nm, {'tag': '?', 'content': '', 'tooltip': ''})
        says = e.get('tooltip') or e.get('content') or e.get('automation') or ''
        says = says.replace('|', '/').strip()
        if len(says) > 150:
            says = says[:147] + '...'
        evs = ', '.join(sorted(set(h['event'] for h in wired[nm])))
        calls = sorted(set(c for h in wired[nm] for c in h['calls']))
        cl = ', '.join('`%s`' % c for c in calls[:6])
        if len(calls) > 6:
            cl += ' +%d' % (len(calls) - 6)
        md.append('| `%s` | %s | %s | %s | %s |' % (nm, e['tag'], says, evs, cl))
    md.append('')

    md.append('## Named controls with no handler')
    md.append('')
    md.append('Labels, containers and read-only surfaces - plus anything that was wired')
    md.append('once and is not any more. Check each before rebuilding it.')
    md.append('')
    md.append('| control | kind | says |')
    md.append('|---|---|---|')
    for nm in sorted(k for k in els if k not in wired):
        e = els[nm]
        says = (e.get('tooltip') or e.get('content') or e.get('automation') or '').replace('|', '/').strip()
        if len(says) > 110:
            says = says[:107] + '...'
        md.append('| `%s` | %s | %s |' % (nm, e['tag'], says))
    md.append('')

    mi = menu_items()
    md.append('## Right-click menu actions')
    md.append('')
    md.append('| label | calls | line |')
    md.append('|---|---|---|')
    for m in mi:
        md.append('| %s | %s | `%d` |' % (m['label'], ', '.join('`%s`' % c for c in m['calls'][:6]) or '-', m['line']))
    md.append('')

    md.append('## Keyboard shortcuts on the window')
    md.append('')
    md.append('In tunnel order - the first rule that matches wins, and that ORDER is')
    md.append('load-bearing: it is what the 2026-09-09 Escape defect was.')
    md.append('')
    md.append('`' + '`, `'.join(shortcuts()) + '`')
    md.append('')

    md.append('## Timers')
    md.append('')
    md.append('| timer | interval | line |')
    md.append('|---|---|---|')
    for t in timers():
        md.append('| `%s` | `%s` | `%d` |' % (t['name'], t['interval'], t['line']))
    md.append('')

    md.append('## Cadences and budgets')
    md.append('')
    md.append('The numbers that decide how live the tool feels. Every one was chosen')
    md.append('against a measurement; see the knowledge ledger for which.')
    md.append('')
    md.append('| name | value | line |')
    md.append('|---|---|---|')
    for c in cadences():
        md.append('| `%s` | `%s` | `%d` |' % (c['name'], c['value'], c['line']))
    md.append('')

    io.open(os.path.join(OUT, '01-CAPABILITIES.md'), 'w', encoding='utf-8').write('\n'.join(md))
    io.open(os.path.join(OUT, 'surface.json'), 'w', encoding='utf-8').write(json.dumps(
        {'elements': els, 'handlers': hs, 'menu': mi, 'timers': timers(),
         'cadences': cadences(), 'shortcuts': shortcuts()}, indent=1, ensure_ascii=False))

    print('%d named elements, %d wired (%d unwired), %d menu actions, %d timers'
          % (len(els), len(wired), len(els) - len(wired), len(mi), len(timers())))
    print('-> rebuild/01-CAPABILITIES.md')


if __name__ == '__main__':
    main()

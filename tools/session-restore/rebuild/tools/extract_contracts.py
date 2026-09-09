# Extract every EXTERNAL CONTRACT the tool depends on.
#
# WHY THIS ONE MATTERS MOST FOR A REBUILD. Everything inside the tool can be
# redesigned freely. Everything at its edge cannot: the console API it calls,
# the CLI it shells out to, the files it reads and writes, and the settings the
# operator already has in his config. Those are fixed points, and a rebuild that
# gets one of them subtly wrong fails in production rather than in a test.
#
# The settings especially - the operator's session-restore.config.json exists
# and must keep working. Every key, its default and its allowed values are
# declared in $SR_CfgMeta, so they are read from there rather than transcribed.
#
# Usage:  python rebuild/tools/extract_contracts.py
# Writes: rebuild/03-CONTRACTS.md, rebuild/contracts.json
import io, os, re, json

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
OUT = os.path.join(ROOT, 'rebuild')

FILES = ['lib/_common.ps1', 'lib/sessions-window.ps1', 'app/SessionsHost.cs']


def read(rel):
    p = os.path.join(ROOT, rel)
    return io.open(p, encoding='utf-8', errors='replace').read() if os.path.exists(p) else ''


def pinvokes():
    """The native surface. In C# these stop being strings and become real
    signatures - this is the part of the rebuild that gets strictly easier."""
    out = []
    for rel in FILES:
        src = read(rel)
        for m in re.finditer(
                r'\[DllImport\("([^"]+)"([^\]]*)\)\]\s*'
                r'(?:public\s+|private\s+|internal\s+|static\s+|extern\s+)*'
                r'([\w\[\]<>,\s\.]+?)\s+(\w+)\s*\(([^;]*?)\)\s*;', src, re.S):
            out.append({
                'file': rel,
                'line': src.count('\n', 0, m.start()) + 1,
                'dll': m.group(1),
                'opts': ' '.join(m.group(2).split()).strip(', '),
                'returns': ' '.join(m.group(3).split()),
                'name': m.group(4),
                'args': ' '.join(m.group(5).split()),
            })
    return out


def processes():
    """Everything the tool shells out to. Each is a behaviour contract with a
    program this repo does not own."""
    pats = [
        (r"claude\s+agents\s+--json", 'claude agents --json', 'the agent/session map'),
        (r"claude\s+--resume", 'claude --resume', 'reopen a conversation'),
        (r"claude\s+auth\s+status", 'claude auth status', 'is the login live'),
        (r"claude\s+setup-token", 'claude setup-token', 'sign in'),
        (r"wt\.exe", 'wt.exe', 'Windows Terminal - open and focus tabs'),
        (r"taskkill", 'taskkill', 'end a session process'),
        (r"Get-CimInstance", 'CIM/WMI', 'process tree and command lines'),
        (r"Get-Process\b", 'Get-Process', 'liveness by pid'),
    ]
    out = {}
    for rel in FILES:
        src = read(rel)
        for pat, name, why in pats:
            n = len(re.findall(pat, src))
            if n:
                e = out.setdefault(name, {'name': name, 'why': why, 'sites': {}})
                e['sites'][rel] = n
    return list(out.values())


def paths():
    """Files and directories the tool reads or writes."""
    hits = {}
    pats = [
        (r"sessions-registry\.json", 'sessions-registry.json', 'THE state file - conversations, ticks, projects'),
        (r"session-restore\.config\.json", 'session-restore.config.json', 'the operator settings'),
        (r"\.claude[\\/]+projects", '~/.claude/projects', 'transcripts (.jsonl), read only'),
        (r"\.state[\\/]", '.state/', 'logs, spliced harnesses, scratch'),
        (r"restore\.log", '.state/restore.log', 'the log to read when it seems dead'),
        (r"window2\.xaml", 'lib/window2.xaml', 'the UI tree'),
        (r"lib[\\/]+fonts", 'lib/fonts/', 'Manrope and IBM Plex Mono, shipped'),
        (r"\.claude[\\/]+settings\.json", '~/.claude/settings.json', 'read for permissions/model'),
    ]
    for rel in FILES + ['lib/restore-sessions.ps1']:
        src = read(rel)
        for pat, name, why in pats:
            n = len(re.findall(pat, src, re.I))
            if n:
                e = hits.setdefault(name, {'path': name, 'why': why, 'sites': {}})
                e['sites'][rel] = n
    return list(hits.values())


def settings():
    """$SR_CfgMeta - the operator's config file contract. Read from the source
    of truth: a transcribed copy is a copy that goes stale.

    🪤 THE TABLE HAS TO BE BOUNDED BY ITS BRACES, not by a character count. A
    fixed window ran past the end of it and swallowed $script:termChords, so
    'C', 'D' and 'Z' were reported as settings. A spec that invents three
    settings is worse than one that misses them: somebody would build them."""
    src = read('lib/sessions-window.ps1')
    i = src.find('$script:SR_CfgMeta')
    if i < 0:
        return []
    j = src.index('{', i)
    d, k = 0, j
    while k < len(src):
        if src[k] == '{':
            d += 1
        elif src[k] == '}':
            d -= 1
            if d == 0:
                break
        k += 1
    blob = src[j:k + 1]
    out = []
    for m in re.finditer(r"(?m)^(\s+)'([A-Za-z]\w*)'\s*=\s*@\{", blob):
        start = blob.index('{', m.end() - 1)
        d2, e = 0, start
        while e < len(blob):
            if blob[e] == '{':
                d2 += 1
            elif blob[e] == '}':
                d2 -= 1
                if d2 == 0:
                    break
            e += 1
        body = blob[start:e]

        def f(name):
            # 🪤 AN OPTION LIST IS @('a','b','c') AND SPANS THE COMMA. Stopping
            # at the first delimiter reported every choice list as "@(" - which
            # would have told the rebuild that these settings are free text.
            a = re.search(r"\b%s\s*=\s*@\(" % name, body)
            if a:
                d3, e3 = 0, body.index('(', a.end() - 1)
                while e3 < len(body):
                    if body[e3] == '(':
                        d3 += 1
                    elif body[e3] == ')':
                        d3 -= 1
                        if d3 == 0:
                            break
                    e3 += 1
                inner = body[body.index('(', a.end() - 1) + 1:e3]
                # An option is @{ V = 'value'; L = 'what the screen calls it' }.
                # The rebuild needs V - L is a label it will write itself.
                vs = re.findall(r"\bV\s*=\s*'([^']*)'", inner)
                if vs:
                    return ', '.join(vs)
                return ', '.join(x.strip().strip("'\"") for x in inner.split(',') if x.strip())
            a = re.search(r"\b%s\s*=\s*('([^']*)'|\"([^\"]*)\"|[^;\r\n}]+)" % name, body)
            if not a:
                return ''
            v = a.group(2) if a.group(2) is not None else (a.group(3) if a.group(3) is not None else a.group(1))
            return (v or '').strip()
        opts = f('Options')
        rng = ''
        if f('Min') or f('Max'):
            rng = '%s..%s' % (f('Min') or '?', f('Max') or '?')
        out.append({
            'key': m.group(2),
            'group': f('Group'),
            'label': f('Label'),
            'default': f('Default'),
            'options': opts,
            'flags': f('Flags'),
            'range': rng,
            'help': f('Help'),
            'line': src.count('\n', 0, i) + blob.count('\n', 0, m.start()) + 1,
        })
    return out


def main():
    pi, pr, pa, st = pinvokes(), processes(), paths(), settings()

    md = []
    md.append('# The external contracts')
    md.append('')
    md.append('**Generated by `rebuild/tools/extract_contracts.py` - do not edit by hand.**')
    md.append('')
    md.append('Everything inside the tool can be redesigned. Everything on this page cannot:')
    md.append('it is the edge, and a rebuild that gets one of these subtly wrong fails in')
    md.append('use rather than in a test.')
    md.append('')

    md.append('## The native surface (%d imports)' % len(pi))
    md.append('')
    md.append('🔑 **This is the part of the rebuild that gets strictly EASIER.** In')
    md.append('PowerShell each of these is a C# fragment inside a string, compiled at')
    md.append('startup by `Add-Type`, with no compiler checking the marshalling. In C# they')
    md.append('are ordinary signatures the compiler checks.')
    md.append('')
    md.append('| dll | function | returns | arguments | where |')
    md.append('|---|---|---|---|---|')
    for p in sorted(pi, key=lambda x: (x['dll'], x['name'])):
        md.append('| %s | `%s` | `%s` | `%s` | `%s:%d` |'
                  % (p['dll'], p['name'], p['returns'], p['args'][:90], p['file'], p['line']))
    md.append('')

    md.append('## Programs this tool shells out to')
    md.append('')
    md.append('🔴 **None of these are owned by this repo.** Their output format is a')
    md.append('contract nobody signed, and the knowledge ledger records what was learned')
    md.append('about each the hard way.')
    md.append('')
    md.append('| program | what it is for | call sites |')
    md.append('|---|---|---|')
    for p in sorted(pr, key=lambda x: x['name']):
        sites = ', '.join('%s x%d' % (os.path.basename(k), v) for k, v in sorted(p['sites'].items()))
        md.append('| `%s` | %s | %s |' % (p['name'], p['why'], sites))
    md.append('')

    md.append('## Files and directories')
    md.append('')
    md.append('| path | what it is | touched in |')
    md.append('|---|---|---|')
    for p in sorted(pa, key=lambda x: x['path']):
        sites = ', '.join(os.path.basename(k) for k in sorted(p['sites']))
        md.append('| `%s` | %s | %s |' % (p['path'], p['why'], sites))
    md.append('')
    md.append('🔴 **`sessions-registry.json` and `session-restore.config.json` are LIVE**')
    md.append('operator files. A registry-overwrite bug in this repo\'s history cost 210')
    md.append('conversations - which is why the write guards are strict, and why a rebuild')
    md.append('must reproduce them before it is allowed to write anything at all.')
    md.append('')

    md.append('## Settings (%d)' % len(st))
    md.append('')
    md.append('The operator\'s existing `session-restore.config.json` must keep working, so')
    md.append('every key here is a fixed point - name, default and allowed values.')
    md.append('An unset key is DRAWN at its default and never written.')
    md.append('')
    md.append('| key | group | default | allowed | shown as |')
    md.append('|---|---|---|---|---|')
    for s in sorted(st, key=lambda x: (x['group'], x['key'])):
        allowed = s['options'] or s['flags'] or s['range'] or ''
        md.append('| `%s` | %s | `%s` | %s | %s |'
                  % (s['key'], s['group'], s['default'] or '(unset)', allowed[:60], s['label']))
    md.append('')

    io.open(os.path.join(OUT, '03-CONTRACTS.md'), 'w', encoding='utf-8').write('\n'.join(md))
    io.open(os.path.join(OUT, 'contracts.json'), 'w', encoding='utf-8').write(json.dumps(
        {'pinvoke': pi, 'processes': pr, 'paths': pa, 'settings': st}, indent=1, ensure_ascii=False))
    print('%d p/invoke, %d programs, %d paths, %d settings' % (len(pi), len(pr), len(pa), len(st)))
    print('-> rebuild/03-CONTRACTS.md')


if __name__ == '__main__':
    main()

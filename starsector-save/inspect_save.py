#!/usr/bin/env python3
"""Inspect Starsector save slots without loading the game.

Usage:
  inspect_save.py [--saves DIR] slots                 # every slot: save date, level, location, autosave
  inspect_save.py [--saves DIR] summary [SLOT]        # newest slot (or SLOT): captain, credits, story points, fleet, cargo
  inspect_save.py [--saves DIR] flags   [SLOT] [PREFIX]  # real memory flags ($ga by default)
  inspect_save.py [--saves DIR] missions [SLOT]       # Academy mission objects and their current stage
  inspect_save.py [--saves DIR] markets [SLOT] [COMMODITY...]  # per-market stock/supply/demand (default supplies fuel)

SLOT is a save directory name (save_Adamr_...) or the word "newest" (default).
The default saves dir is the desktop install; pass --saves for a copy pulled from the Deck or the share.
"""
import re, sys, os, glob, argparse

DEFAULT_SAVES = os.path.expanduser('~/.local/share/starsector/saves')

def load(path):
    return open(path, encoding='utf-8', errors='replace').read()

def slot_dirs(saves):
    return sorted(d for d in glob.glob(os.path.join(saves, 'save_*')) if os.path.isfile(os.path.join(d, 'descriptor.xml')))

def desc_fields(d):
    t = load(os.path.join(d, 'descriptor.xml'))
    g = lambda tag: (re.search(rf'<{tag}[^>]*>([^<]*)</{tag}>', t) or [None, '?'])[1]
    ts = re.search(r'<gameDate[^>]*>.*?<timestamp>(-?\d+)</timestamp>', t, re.S)
    return dict(slot=os.path.basename(d), saveDate=g('saveDate'), level=g('characterLevel'),
                location=g('locDesc'), autosave=g('autosave'), gameVersion=g('gameVersion'),
                gameTs=int(ts.group(1)) if ts else 0)

def newest(saves):
    ds = slot_dirs(saves)
    if not ds: sys.exit(f'no slots under {saves}')
    return max(ds, key=lambda d: desc_fields(d)['saveDate'])

def pick(saves, slot):
    if slot in (None, 'newest'): return newest(saves)
    p = os.path.join(saves, slot)
    if not os.path.isdir(p): sys.exit(f'no such slot: {p}')
    return p

def cmd_slots(a):
    rows = [desc_fields(d) for d in slot_dirs(a.saves)]
    for r in sorted(rows, key=lambda r: r['saveDate']):
        print(f"{r['saveDate'][:19]}  lvl {r['level']:>2}  auto={r['autosave']:<5}  {r['location']:<26}  {r['slot']}")

def player_fleet_block(s):
    # <playerFleet ref="N"> -> <Flt z="N"> -> its <fD ... nSf="player"> member list, then the fleet's <cargo z=...>
    pf = re.search(r'<playerFleet ref="(\d+)"', s)
    i = s.find(f'<Flt z="{pf.group(1)}"') if pf else s.find('n="Player Fleet"')
    fd = s.find('nSf="player"', i)
    m = s.find('<m z=', fd)
    c = s.find('<cargo z=', m)
    return s[m:c], s[c:c+60000]

def cmd_summary(a):
    d = pick(a.saves, a.slot); s = load(os.path.join(d, 'campaign.xml'))
    f = desc_fields(d)
    print(f"slot {f['slot']}  saved {f['saveDate'][:19]}  game {f['gameVersion']}  location: {f['location']}")
    st = re.search(r'<c z="\d+" id="p_[^"]*"[^>]*fid="player"[^>]*>\s*<n z="\d+" f="([^"]*)"[^>]*>.*?<stats z="\d+"[^>]*xp="(\d+)"[^>]*l="(\d+)"[^>]*pt="(\d+)"[^>]*sp="(\d+)"[^>]*>\s*<a>([^<]*)</a>\s*<s>([^<]*)</s>', s, re.S)
    if st:
        skills = [k for k, v in re.findall(r'"(\w+)":(\d+)', st.group(7)) if v != '0']
        print(f"captain {st.group(1)}: level {st.group(3)}, xp {st.group(2)}, unspent skill pts {st.group(4)}, story points {st.group(5)}")
        print("skills:", ', '.join(skills))
    members, cargo = player_fleet_block(s)
    print("\nfleet:")
    for mm in re.finditer(r'<FMmbr z="\d+"([^>]*)>', members):
        at = dict(re.findall(r'(\w+)="([^"]*)"', mm.group(1)))
        blk = members[mm.end():mm.end()+60000]
        sv = re.search(r'<savedVariant([^>]*)>', blk)
        hull = dict(re.findall(r'(\w+)="([^"]*)"', sv.group(1))).get('hId', '?') if sv else '?'
        cap = re.search(r'<c [^>]*pst="(fleetCommander|officer)"[^>]*>\s*<n [^>]*f="([^"]*)"', blk[:blk.find('</FMmbr>')] if '</FMmbr>' in blk else blk)
        print(f"  {at.get('sN','?'):<32} {hull:<26} {('captain: '+cap.group(2)) if cap else ''}")
    cr = re.search(r'<c z="\d+">\s*<value>([0-9.]+)</value>', cargo)
    print("\ncredits:", cr.group(1) if cr else '?')
    print("cargo:", ', '.join(f"{n} {float(q):.0f}" for q, n in re.findall(r's="([0-9.]+)"[^>]*>\s*<d cl="st">([a-z_]+)</d>', cargo)))

def cmd_flags(a):
    d = pick(a.saves, a.slot); s = load(os.path.join(d, 'campaign.xml'))
    pre = re.escape(a.prefix or '$ga')
    seen = {}
    for m in re.finditer(rf'<st>({pre}[A-Za-z0-9_]*)</st>\s*<(bp|st|fp|ip|Lp)>([^<]*)</\2>', s):
        seen.setdefault(m.group(1), m.group(3))
    for k in sorted(seen): print(f"{k} = {seen[k]}")
    print(f"\n({len(seen)} real memory entries; <key> tags inside mission objects are scripted actions, NOT state)")

def cmd_missions(a):
    d = pick(a.saves, a.slot); s = load(os.path.join(d, 'campaign.xml'))
    im = s.find('<intelManager'); ime = s.find('</intelManager>', im); intel = s[im:ime]
    pat = r'<(?:(com\.fs\.starfarer\.api\.impl\.campaign\.missions\.[A-Za-z.]+) z="(\d+)"|[A-Za-z]+ cl="(com\.fs\.starfarer\.api\.impl\.campaign\.missions\.[A-Za-z.]+)" z="(\d+)")[^>]*>'
    seen = set()
    for m in re.finditer(pat, s):
        cls = m.group(1) or m.group(3); z = m.group(2) or m.group(4)
        if z in seen: continue
        seen.add(z)
        blk = s[m.start():m.start()+80000]
        cur = re.search(r'<currentStage[^>]*>([^<]*)<', blk)
        if not cur: continue
        order = []
        for st in re.findall(rf'<{re.escape(cls)}_-Stage>([A-Z_]+)</', blk):
            if st not in order: order.append(st)
        short = cls.split('.')[-1]
        active = f'{short} ref="{z}"' in intel or f'cl="{cls}" ref="{z}"' in intel
        print(f"{short:<24} stage {cur.group(1):<24} {'in intel list' if active else ''}  order: {' > '.join(order)}")

def cmd_markets(a):
    d = pick(a.saves, a.slot); s = load(os.path.join(d, 'campaign.xml'))
    coms = a.rest or ['supplies', 'fuel']
    starts = [m.start() for m in re.finditer(r'<market cl="Market" z="\d+">', s)]
    print(f"{'market':<24}{'sz':<3}{'faction':<15}" + ''.join(f"| {c:<30}" for c in coms))
    for i, p in enumerate(starts):
        blk = s[p:min(starts[i+1] if i+1 < len(starts) else p+400000, p+400000)]
        name = (re.search(r'<name>([^<]*)</name>', blk) or [0, '?'])[1]
        size = (re.search(r'<size>(\d+)</size>', blk) or [0, '?'])[1]
        fac = (re.search(r'<factionId>([^<]*)</factionId>', blk) or [0, '?'])[1]
        cells = []
        for c in coms:
            m = re.search(rf'<COMkt z="\d+" c="{c}"([^>]*)>(.*?)</COMkt>', blk, re.S)
            if not m: cells.append('-'); continue
            at = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
            av = re.search(r'<available[^>]*m="([-0-9.]+)"', m.group(2))
            avail = float(av.group(1)) if av else 0.0; need = int(at.get('mD', 0))
            tag = 'EXCESS' if avail > need else ('DEFICIT' if avail < need else 'met')
            cells.append(f"stock {float(at.get('sto',0)):>6.0f} {avail:.0f}/{need} {tag}")
        if any(x != '-' for x in cells):
            print(f"{name[:23]:<24}{size:<3}{fac[:14]:<15}" + ''.join(f"| {x:<30}" for x in cells))

if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--saves', default=DEFAULT_SAVES)
    ap.add_argument('cmd', choices=['slots', 'summary', 'flags', 'missions', 'markets'])
    ap.add_argument('slot', nargs='?', default='newest')
    ap.add_argument('rest', nargs='*')
    a = ap.parse_args()
    a.prefix = a.rest[0] if a.cmd == 'flags' and a.rest else None
    {'slots': cmd_slots, 'summary': cmd_summary, 'flags': cmd_flags, 'missions': cmd_missions, 'markets': cmd_markets}[a.cmd](a)

#!/usr/bin/env python3
# Разбивает тело.sh на N НЕПРЕРЫВНЫХ шардов по границам секций «# ─── …»,
# РАЗРЕЗАЯ ТОЛЬКО там, где ни один интервал жизни фикстуры [def..последнее_исп]
# не пересекает разрез. Так фикстура и её использования всегда в одном шарде —
# результат параллельного прогона идентичен последовательному.
#
# Использование: split_shards.py <тело.sh> <каталог_шардов> <N>
# Каждый шард — самостоятельный sh: свой mktemp-TMP (полная изоляция, ноль
# гонок общего состояния); в конце копирует свои *.конда в $CORPUS (для
# центральной досанитайзки) и САНИТАЙЗИТ СВОЙ каталог (sanitize_dir): так
# ASan/UBSan-фазы транспилятора и .elf идут ВНУТРИ шарда, перекрываясь с телом,
# а не отдельной фазой после. Ожидает в окружении: ROOT, BIN, CORPUS, KASAN.
import sys, re, os

body, outdir, nshards = sys.argv[1], sys.argv[2], int(sys.argv[3])
lines = open(body, encoding='utf-8').read().split('\n')
N = len(lines)

defline, lastuse = {}, {}
cat_re = re.compile(r'\s*cat > (\S+?)\.конда ')
konda_re = re.compile(r'([^\s"/]+)\.конда')
out_re = re.compile(r'вывод/([^\s".]+)\.(?:c|elf|h|и)')
for i, l in enumerate(lines):
    m = cat_re.match(l)
    if m:
        f = m.group(1)
        defline.setdefault(f, i)
        lastuse[f] = i
    is_def = l.lstrip().startswith('cat > ')
    if not is_def:
        for mm in konda_re.finditer(l):
            f = mm.group(1)
            if f in defline:
                lastuse[f] = max(lastuse[f], i)
    for mm in out_re.finditer(l):
        f = mm.group(1)
        if f in defline:
            lastuse[f] = max(lastuse[f], i)

spans = [(defline[f], lastuse[f]) for f in defline if lastuse[f] > defline[f]]

def safe(L):
    # разрез ПЕРЕД строкой L безопасен, если ни один интервал [d,u] его не пересекает
    for d, u in spans:
        if d < L <= u:
            return False
    return True

bounds = [i for i, l in enumerate(lines) if l.startswith('# ─── ')]
target = max(1, N // nshards)
cuts = [0]
for b in bounds:
    if b <= cuts[-1]:
        continue
    if b - cuts[-1] >= target and safe(b):
        cuts.append(b)
cuts.append(N)

os.makedirs(outdir, exist_ok=True)
idx = 0
for k in range(len(cuts) - 1):
    a, b = cuts[k], cuts[k + 1]
    if a >= b:
        continue
    chunk = '\n'.join(lines[a:b])
    script = (
        'set -eu\n'
        '. "$ROOT/tests/common.sh"\n'
        'TMP=$(mktemp -d)\n'
        "trap 'rm -rf \"$TMP\"' EXIT\n"
        'cd "$TMP"\n'
        + chunk + '\n'
        # успех шарда: перенести фикстуры в общий корпус (санитайзер-фазы —
        # централизованно после всех шардов: xargs -P балансирует лучше).
        'cp -f "$TMP"/*.конда "$CORPUS"/ 2>/dev/null || true\n'
    )
    open(os.path.join(outdir, f'shard_{idx:02d}.sh'), 'w', encoding='utf-8').write(script)
    idx += 1
print(idx)

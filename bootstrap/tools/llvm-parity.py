#!/usr/bin/env python3
# llvm 通道全文对账：同一输入两侧发射，规范化后按差异类型归因并出读数表。
# 只读测量：产物落构建目录，不写源码树；读数供通道面对账引用，不作常驻门禁。

import argparse
import difflib
import os
import re
import subprocess
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOCAL = re.compile(r'%[A-Za-z0-9_.$-]+')
LABEL_DEF = re.compile(r'^([A-Za-z0-9_.$-]+):')
TYPED_PTR = re.compile(r'(\b(?:i[0-9]+|half|float|double|x86_fp80)|%[A-Za-z0-9_.$-]+)\*')
GLOBAL_DEF = re.compile(r'^@([A-Za-z0-9_.$-]+)\s*=\s*(.*)$')
DECLARE = re.compile(r'^declare\s+(.*)$')
ALLOCA = re.compile(r'^%[A-Za-z0-9_.$-]+ = alloca\b')
RELEASE = re.compile(r'release')
EB0X = re.compile(r'^%[A-Za-z0-9_.$-]+ = alloca \[8 x i8\], align 8$')

HEADER = [
    '# llvm 通道全文对账：两侧发射的行数、函数集、声明集、全局集与函数体残差。',
    '# 「去归还/去跳板/同指令集」三列是在规范化阶梯上逐级放宽后仍相同的函数数。',
    '# 由 bootstrap/tools/llvm-parity.py 生成，勿手改；读数易腐，重取即整表重写。',
]


def fail(message):
    print(f' 行不通  [llvm通道] {message}', file=sys.stderr)
    return 2


def norm_ptr(line):
    prev = None
    while prev != line:
        prev = line
        line = TYPED_PTR.sub('ptr', line)
    return line


def split_module(text):
    """拆成 (前导行, [(函数名, 签名行, 体行)])；注释行不进两侧比对。"""
    lines = [l for l in text.splitlines() if not l.lstrip().startswith(';')]
    head, funcs, cur = [], [], None
    for line in lines:
        if line.startswith('define '):
            m = re.search(r'@([A-Za-z0-9_.$-]+)\s*\(', line)
            cur = [m.group(1) if m else '?', line, []]
            funcs.append(cur)
        elif cur is not None:
            if line.strip() == '}':
                cur = None
            else:
                cur[2].append(line)
        else:
            head.append(line)
    return head, funcs


def canon_sig(line):
    return re.sub(r'\s+', ' ', LOCAL.sub('%p', norm_ptr(line))).strip()


def canon_body(body):
    """去入口标签与环境箱，指针归一，局部名、标签与串常量按首现重编号，槽分配提表头。"""
    kept = []
    for line in body:
        s = line.strip()
        if s == 'entry:' or EB0X.match(s):
            continue
        kept.append(norm_ptr(line))
    local_map, label_map, str_map, out = {}, {}, {}, []

    def label(name):
        if name not in label_map:
            label_map[name] = 'L%d' % len(label_map)
        return label_map[name]

    for line in kept:
        m = LABEL_DEF.match(line)
        if m:
            line = label(m.group(1)) + ':' + line[m.end():]
        line = re.sub(r'label %([A-Za-z0-9_.$-]+)', lambda mo: 'label %' + label(mo.group(1)), line)
        line = re.sub(r'@\.str\d+', lambda mo: str_map.setdefault(mo.group(0), '@.str%d' % len(str_map)), line)

        def loc(mo):
            name = mo.group(0)
            if name not in local_map:
                local_map[name] = '%%v%d' % len(local_map)
            return local_map[name]

        out.append(re.sub(r'[ \t]+', ' ', LOCAL.sub(loc, line)).strip())

    return sorted(l for l in out if ALLOCA.match(l)) + [l for l in out if not ALLOCA.match(l)]


def drop_release(lines):
    """去掉归还调用，并清掉只喂给归还的装载与取址，让两侧的槽读法可比。"""
    out = [l for l in lines if not RELEASE.search(l)]
    for _ in range(8):
        used = set()
        for l in out:
            used |= set(LOCAL.findall(l.split('=', 1)[1] if '=' in l else l))
        new = []
        for l in out:
            m = re.match(r'^(%[A-Za-z0-9_.$-]+) = (load|alloca|getelementptr)\b', l)
            if m and m.group(1) not in used:
                continue
            new.append(l)
        if new == out:
            break
        out = new
    return out


def collapse_trampolines(lines):
    """抹掉 `Lx:` 紧跟 `br label Ly` 的空跳板，并把指向 Lx 的分支改指 Ly。"""
    lines = list(lines)
    changed = True
    while changed:
        changed = False
        for i in range(len(lines) - 1):
            a, b = lines[i], lines[i + 1]
            if a.endswith(':') and b.startswith('br label %'):
                src, dst = a[:-1], b[len('br label %'):]
                if src != dst:
                    lines = [l.replace('label %' + src, 'label %' + dst) for l in lines]
                del lines[i:i + 2]
                changed = True
                break
    order, out = {}, []
    for l in lines:
        m = LABEL_DEF.match(l)
        if m:
            order.setdefault(m.group(1), 'L%d' % len(order))
            l = order[m.group(1)] + ':' + l[m.end():]
        l = re.sub(r'label %([A-Za-z0-9_.$-]+)',
                   lambda mo: 'label %' + order.setdefault(mo.group(1), 'L%d' % len(order)), l)
        out.append(l)
    return out


def classify(host_lines, self_lines):
    """按编辑块的内容给差异打标；一个函数可命中多类。"""
    tags = set()
    sm = difflib.SequenceMatcher(a=host_lines, b=self_lines, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == 'equal':
            continue
        h, s = host_lines[i1:i2], self_lines[j1:j2]
        joined = ' '.join(h + s)
        if RELEASE.search(joined):
            tags.add('归还/所有权')
        elif any(l.endswith(':') for l in h + s) or any(l.startswith('br label') for l in h + s):
            tags.add('分支结构')
        elif 'call' in joined:
            tags.add('调用/指令选择')
        elif 'alloca' in joined:
            tags.add('槽分配')
        elif 'load ' in joined or 'store ' in joined:
            tags.add('槽读写')
        elif 'getelementptr' in joined:
            tags.add('地址计算')
        elif op == 'replace':
            tags.add('字面量/字段')
        else:
            tags.add('其它')
    return tags


def measure(host_ll, self_ll):
    htext = open(host_ll, encoding='utf-8').read()
    stext = open(self_ll, encoding='utf-8').read()
    hh, hf = split_module(htext)
    sh, sf = split_module(stext)
    hmap = {n: (sig, body) for n, sig, body in hf}
    smap = {n: (sig, body) for n, sig, body in sf}
    common = [n for n, _, _ in hf if n in smap]

    same = sig_diff = 0
    tags = Counter()
    eq_release = eq_tramp = eq_multi = 0
    for n in common:
        if canon_sig(hmap[n][0]) != canon_sig(smap[n][0]):
            sig_diff += 1
        hb, sb = canon_body(hmap[n][1]), canon_body(smap[n][1])
        if hb == sb:
            same += 1
            eq_release += 1
            eq_tramp += 1
            eq_multi += 1
            continue
        for t in classify(hb, sb):
            tags[t] += 1
        hr, sr = drop_release(hb), drop_release(sb)
        if hr == sr:
            eq_release += 1
        if collapse_trampolines(hr) == collapse_trampolines(sr):
            eq_tramp += 1
        if Counter(hr) == Counter(sr):
            eq_multi += 1

    hdecl = {DECLARE.match(l).group(1) for l in hh if DECLARE.match(l)}
    sdecl = {DECLARE.match(l).group(1) for l in sh if DECLARE.match(l)}
    hglob = {GLOBAL_DEF.match(l).group(1) for l in hh if GLOBAL_DEF.match(l)}
    sglob = {GLOBAL_DEF.match(l).group(1) for l in sh if GLOBAL_DEF.match(l)}

    def structural(text):
        # 函数按名排序：宿主自身的函数顺序两跑就不同，排序后才能稳定地量函数体差
        _, funcs = split_module(text)
        out = []
        for _, sig, body in sorted(funcs, key=lambda f: f[0]):
            out.append(sig)
            out.extend(body)
            out.append('}')
        return [l for l in out if l.strip()]

    hbody, sbody = structural(htext), structural(stext)
    first = '-'
    for name in sorted(n for n, _, _ in hf if n in smap):
        if canon_body(hmap[name][1]) != canon_body(smap[name][1]):
            first = name
            break
    diff_lines = 0
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(a=hbody, b=sbody, autojunk=False).get_opcodes():
        if op != 'equal':
            diff_lines += (i2 - i1) + (j2 - j1)

    def indent(fs):
        for _, _, body in fs:
            for l in body:
                if l.strip() and not l.strip().endswith(':'):
                    return len(l) - len(l.lstrip())
        return 0

    return {
        'lines': (len(htext.splitlines()), len(stext.splitlines())),
        'defines': (len(hf), len(sf)),
        'declares': (len(hdecl), len(sdecl)),
        'fn_only_host': sorted(set(hmap) - set(smap)),
        'fn_only_self': sorted(set(smap) - set(hmap)),
        'order_same': [n for n, _, _ in hf] == [n for n, _, _ in sf],
        'fn_same': same,
        'fn_common': len(common),
        'sig_diff': sig_diff,
        'tags': tags,
        'eq_release': eq_release,
        'eq_tramp': eq_tramp,
        'eq_multi': eq_multi,
        'decl_only_host': sorted(hdecl - sdecl),
        'decl_only_self': sorted(sdecl - hdecl),
        'glob_only_host': sorted(hglob - sglob),
        'glob_only_self': sorted(sglob - hglob),
        'first_diff': first,
        'diff_lines': diff_lines,
        'indent': (indent(hf), indent(sf)),
        'head': (len([l for l in htext.splitlines() if l.lstrip().startswith(';')]),
                 len([l for l in stext.splitlines() if l.lstrip().startswith(';')])),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default=os.path.join(ROOT, '.build/release/pini'))
    ap.add_argument('--self', default=os.path.join(ROOT, 'bootstrap/.build/release/bin/pini-bootstrap'))
    ap.add_argument('--out', default=os.path.join(ROOT, 'bootstrap/.build/tmp/llvm-parity'))
    ap.add_argument('--tsv')
    ap.add_argument('paths', nargs='*')
    args = ap.parse_args()

    for binary in (args.host, args.self):
        if not os.path.isfile(binary):
            return fail('缺可执行文件 %s' % binary)
    os.makedirs(args.out, exist_ok=True)
    exdir = os.path.join(ROOT, 'examples')
    paths = args.paths or sorted(os.path.join(exdir, f) for f in os.listdir(exdir) if f.endswith('.pini'))

    rows, totals = [], Counter()
    for path in paths:
        name = os.path.splitext(os.path.basename(path))[0]
        hll = os.path.join(args.out, name + '.host.ll')
        sll = os.path.join(args.out, name + '.self.ll')
        hres = subprocess.run([args.host, 'emit', os.path.abspath(path), '-o', hll],
                              capture_output=True, text=True)
        sres = subprocess.run([args.self, 'emit', os.path.abspath(path), '-o', sll],
                              capture_output=True, text=True)
        if hres.returncode != 0 or sres.returncode != 0:
            rows.append([name, 'skip(%d/%d)' % (hres.returncode, sres.returncode)])
            totals['skip'] += 1
            continue
        m = measure(hll, sll)
        tag_text = ' '.join('%s=%d' % kv for kv in sorted(m['tags'].items(), key=lambda kv: (-kv[1], kv[0])))
        rows.append([
            name,
            '%d/%d' % m['lines'],
            '%d/%d' % m['defines'],
            '%d/%d' % m['declares'],
            '%d/%d' % (m['fn_same'], m['fn_common']),
            '%d/%d/%d' % (m['eq_release'], m['eq_tramp'], m['eq_multi']),
            '同' if m['order_same'] else '异',
            '%d' % m['sig_diff'],
            '%d/%d' % (len(m['fn_only_host']), len(m['fn_only_self'])),
            '%d/%d' % (len(m['decl_only_host']), len(m['decl_only_self'])),
            '%d/%d' % (len(m['glob_only_host']), len(m['glob_only_self'])),
            m['first_diff'],
            '%d' % m['diff_lines'],
            '%d/%d' % m['indent'],
            '%d/%d' % m['head'],
            tag_text or '-',
        ])
        totals['files'] += 1
        totals['host_lines'] += m['lines'][0]
        totals['self_lines'] += m['lines'][1]
        totals['fn_common'] += m['fn_common']
        totals['fn_same'] += m['fn_same']
        totals['sig_diff'] += m['sig_diff']
        totals['eq_release'] += m['eq_release']
        totals['eq_tramp'] += m['eq_tramp']
        totals['eq_multi'] += m['eq_multi']
        totals['diff_lines'] += m['diff_lines']
        for k, v in m['tags'].items():
            totals['tag_' + k] += v
        totals['decl_missing'] += len(m['decl_only_host'])
        totals['glob_missing'] += len(m['glob_only_host'])

    columns = ('程序', '行数宿/自', '函数数宿/自', '声明数宿/自', '体全同/共同', '去归还/去跳板/同指令集',
               '顺序', '签名异', '函数集差', '声明集差', '全局集差', '首差函数', '差行数', '缩进宿/自',
               '注释头宿/自', '残差类型')
    lines = HEADER + ['\t'.join(columns)] + ['\t'.join(r) for r in rows]
    text = '\n'.join(lines)
    print(text)

    print('\n合计：%d 例，行数 %d/%d（%.1f%%），函数体全同 %d/%d，去归还 %d，去跳板 %d，同指令集 %d，'
          '签名异 %d，差行数 %d' % (
              totals['files'], totals['host_lines'], totals['self_lines'],
              100.0 * totals['self_lines'] / max(1, totals['host_lines']),
              totals['fn_same'], totals['fn_common'], totals['eq_release'], totals['eq_tramp'],
              totals['eq_multi'], totals['sig_diff'], totals['diff_lines']))
    print('残差（函数计）：' + ' '.join(
        '%s=%d' % (k[4:], v) for k, v in sorted(totals.items(), key=lambda kv: (-kv[1], kv[0])) if k.startswith('tag_')))
    print('声明缺 %d 条，全局缺 %d 个，跳过 %d 例' % (
        totals['decl_missing'], totals['glob_missing'], totals['skip']))
    if args.tsv:
        with open(args.tsv, 'w', encoding='utf-8') as f:
            f.write(text + '\n')
        print('\n写入 %s' % args.tsv, file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())

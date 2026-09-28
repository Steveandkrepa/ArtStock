"""跨文件接口一致性检查器（字符串/注释感知的词法剥离 + 机械核对）。

做这件事的原因：本机没有 iOS SDK，无法对 SwiftUI/UIKit 层做类型检查。
这两项错误（memberwise init 标签写错、静态成员名打错）语法检查抓不到，
只有类型检查能发现，所以用机械方式补上。
"""
import re, pathlib, sys, collections

ROOT = pathlib.Path("ArtStock")
files = sorted(ROOT.rglob("*.swift"))

def strip_noise(s: str) -> str:
    """把注释与字符串字面量替换为空白，保留换行与长度。

    必须做字符串感知，否则 `"artstock://"` 里的 `//` 会被误当成行注释，
    把后面整个文件吃掉、大括号配平随之失败。
    """
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        # 行注释
        if c == '/' and i + 1 < n and s[i+1] == '/':
            j = s.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j; continue
        # 块注释
        if c == '/' and i + 1 < n and s[i+1] == '*':
            j = s.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(''.join('\n' if ch == '\n' else ' ' for ch in s[i:j])); i = j; continue
        # 原始字符串 / 普通字符串（含多行）
        hashes = 0
        k = i
        while k < n and s[k] == '#':
            hashes += 1; k += 1
        if k < n and s[k] == '"':
            quote = '"' * (3 if s[k:k+3] == '"""' else 1)
            start = k + len(quote)
            close = quote + '#' * hashes
            j = start
            while j < n:
                if s[j] == '\\' and hashes == 0:
                    j += 2; continue
                if s.startswith(close, j):
                    j += len(close); break
                j += 1
            j = min(j, n)
            out.append('#' * hashes + ''.join('\n' if ch == '\n' else ' ' for ch in s[i+hashes:j]))
            i = j; continue
        out.append(c); i += 1
    return ''.join(out)

src = {f: strip_noise(f.read_text(encoding="utf-8")) for f in files}

def match_close(s, open_idx):
    pairs = {'(': ')', '[': ']', '{': '}'}
    stack, i = [], open_idx
    while i < len(s):
        c = s[i]
        if c in '([{': stack.append(pairs[c])
        elif c in ')]}':
            if stack and stack[-1] == c:
                stack.pop()
                if not stack: return i
        i += 1
    return -1

DECL = re.compile(
    r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*'
    r'(?:public\s+|internal\s+|private\s+|fileprivate\s+|package\s+)?'
    r'(?:static\s+|class\s+|nonisolated\s+|final\s+|override\s+|mutating\s+)*'
    r'(?:let|var|func)\s+(\w+)')
CASE = re.compile(r'^\s*case\s+([^\n(]+)')

# 只收「类型体顶层」的 let/var 声明。
# ⚠️ 不能用平铺正则：那样会把函数体内的局部变量（total / hours / ok …）
#    也当成属性，进而让构造参数顺序校验产生一堆假结果（实测踩过）。
STORED = re.compile(
    r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*'
    r'(?:(public|internal|private|fileprivate|package)(\(set\))?\s+)?'
    r'(?:(static|class|nonisolated|final|override|mutating)\s+)*'
    r'(?:let|var)\s+(\w+)\s*[:=]')


def harvest_stored(body):
    """收集**参与 memberwise init** 的存储属性。

    ⚠️ 这里连续踩过三个坑，都用注释标出来免得改回去：

    1. 不能用平铺正则扫整个类型体 —— 函数体内的局部变量
       （total / hours / ok …）会被当成属性。
       → 必须按行扫描，只在行首深度为 0 时收集。

    2. `private` 存储属性**不参与** memberwise init
       （init 的访问级别受最严格的那个属性限制），
       所以 `@State private var now` 这类不该出现在期望参数里。

    3. 计算属性（`var x: T { ... }`）也不参与，只有存储属性才参与。
       用「冒号之后、等号之前出现 `{`」来识别计算属性。
    """
    depth = 0
    for line in body.split('\n'):
        if depth <= 0:
            mm = STORED.match(line)
            if mm:
                access, setter, storage, name = mm.groups()
                is_private_only = (access == 'private' and not setter)
                is_type_level = storage in ('static', 'class')
                # 计算属性：冒号出现在等号之前，且后面跟着 {
                is_computed = re.search(r':[^=]*\{', line) is not None
                if not (is_private_only or is_type_level or is_computed):
                    yield name
        depth += sum(1 if ch in '([{' else -1 if ch in ')]}' else 0 for ch in line)


# 嵌套类型（如 class WeatherService 里的 struct Place）也是可引用成员，
# 只收 let/var/func 会把 `WeatherService.Place` 这类引用误报成错误。
NESTED_TYPE = re.compile(
    r'^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|package\s+)?'
    r'(?:final\s+)?(?:struct|enum|class|actor|protocol|typealias)\s+(\w+)')


def harvest(body):
    depth = 0
    for line in body.split('\n'):
        if depth <= 0:
            mm = DECL.match(line)
            if mm: yield mm.group(1)
            nm = NESTED_TYPE.match(line)
            if nm:
                yield nm.group(1)
            cm = CASE.match(line)
            if cm:
                for c in cm.group(1).split(','):
                    # 依次剥掉关联值 `(Int)` 与显式原始值 `= 0`，
                    # 只认裸 case name 会把带原始值的枚举整个漏掉（实测踩过）。
                    c = c.strip().split('(')[0].split('=')[0].strip()
                    if re.fullmatch(r'\w+', c): yield c
        depth += sum(1 if ch in '([{' else -1 if ch in ')]}' else 0 for ch in line)

TYPE_RE = re.compile(
    r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?'
    r'(?:final\s+)?(enum|struct|class|actor)\s+(\w+)', re.M)
EXT_RE = re.compile(r'^extension\s+(\w+)', re.M)

def body_of(clean, m):
    ob = clean.find('{', m.end())
    if ob < 0: return None
    cb = match_close(clean, ob)
    return None if cb < 0 else clean[ob+1:cb]

members = collections.defaultdict(set)
ViewStructs = {}
declared = set()
for f, clean in src.items():
    for m in TYPE_RE.finditer(clean):
        name = m.group(2); declared.add(name)
        b = body_of(clean, m)
        if b is not None:
            members[name].update(harvest(b))
            # ⚠️ 必须容忍访问修饰符。原来只匹配行首的 `struct`，
            #    于是所有 `private struct XxxView: View` 都被漏掉 ——
            #    实测正是这类结构体里出现了构造参数顺序错误却检查不到。
            if re.search(
                r'^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|package\s+)?'
                r'struct\s+' + re.escape(name) + r'\s*:\s*[^{]*\bView\b',
                clean, re.M):
                ViewStructs[name] = (b, bool(re.search(r'\binit\s*\(', b)))
    for m in EXT_RE.finditer(clean):
        b = body_of(clean, m)
        if b is not None: members[m.group(1)].update(harvest(b))

errors = []

# ---- 检查 A：Type.member 引用 ----
SYNTH = {'allCases','id','rawValue','init','self','Type','hashValue','description','debugDescription',
         'hash','some','none','newValue','oldValue','zero','default','automatic','localizedDescription',
         'errorDescription','failureReason','recoverySuggestion','memoryLayout','superclass'}
refs = 0
for f, clean in src.items():
    for m in re.finditer(r'(?<![\w.])([A-Z]\w*)\.(\w+)', clean):
        t, mem = m.group(1), m.group(2)
        if t not in declared or mem in SYNTH: continue
        refs += 1
        if mem not in members[t]:
            errors.append(f"[成员引用] {f.name}:{clean.count(chr(10),0,m.start())+1}  {t}.{mem}"
                          f"\n            {t} 已声明: {sorted(members[t])}")

# ---- 检查 B：View 的 memberwise init 调用标签 ----
def split_top(s):
    out, depth, buf = [], 0, ""
    for c in s:
        if c in '([{': depth += 1
        elif c in ')]}': depth -= 1
        if c == ',' and depth == 0: out.append(buf); buf = ""
        else: buf += c
    if buf.strip(): out.append(buf)
    return [x.strip() for x in out]

calls = 0
for name, (b, has_init) in ViewStructs.items():
    if has_init: continue
    props = [p for p in harvest(b)]
    # 只保留「存储属性」：排除 func
    stored = list(harvest_stored(b))
    for f, clean in src.items():
        for m in re.finditer(r'(?<![\w.])' + re.escape(name) + r'\s*\(', clean):
            ls = clean.rfind('\n', 0, m.start()) + 1
            if re.match(r'\s*(struct|class|enum|func|static\s+func|case|import|typealias)\b', clean[ls:m.start()]):
                continue
            ob = m.end() - 1
            cb = match_close(clean, ob)
            if cb < 0: continue
            args = split_top(clean[ob+1:cb])
            labels = [re.match(r'(\w+)\s*:', a) for a in args]
            if not args or labels[0] is None: continue
            labs = [mm.group(1) for mm in labels if mm]
            calls += 1
            unknown = [l for l in labs if l not in stored]
            if unknown:
                errors.append(f"[init 标签] {name} @ {f.name}  未知标签 {unknown}；存储属性 {stored}")
            else:
                order = [stored.index(l) for l in labs]
                if order != sorted(order):
                    errors.append(f"[init 标签] {name} @ {f.name}  顺序不符 {labs}；声明顺序 {stored}")

print(f"自有顶层类型        : {len(declared)}")
print(f"View 结构体         : {len(ViewStructs)}（带显式 init 的 {sum(1 for v in ViewStructs.values() if v[1])} 个跳过）")
print(f"核对 Type.member    : {refs} 处")
print(f"核对构造调用标签    : {calls} 处")
if errors:
    print(f"\n❌ {len(errors)} 处问题：")
    for e in errors: print("   " + e)
    sys.exit(1)
print("\n✅ 两项机械核查全部通过")

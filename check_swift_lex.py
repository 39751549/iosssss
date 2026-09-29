# -*- coding: utf-8 -*-
"""Swift 词法自检：括号平衡 + 代码里误入全角字符。

为什么需要它：本机没有 Xcode，iOS 代码唯一的编译验证是 GitHub Actions。
一次 CI 往返要好几分钟，而**括号不匹配**和**代码里混进中文标点**这两类错误
占了手写 Swift 编译失败的一大半 —— 它们不需要类型信息就能查出来，
在本地跑一遍能把大部分低级错误挡在推送之前。

注意：这只是"廉价的前置筛子"，**不能替代真正的编译**。
类型推断、API 签名这类问题（比如 `.frame(width:minHeight:)` 这种不存在的重载）
只有编译器能发现。

用法：
    python check_swift_lex.py                 # 默认扫 ios-native/VoiceRoom/Sources
    python check_swift_lex.py <目录>
"""
import glob
import io
import os
import sys

# 常见全角标点。出现在"代码上下文"（非注释、非字符串）里就是错误。
FULLWIDTH = set('，。；：？！“”‘’（）【】《》、')
FULLWIDTH |= set('０１２３４５６７８９')

PAIRS = {')': '(', ']': '[', '}': '{'}


def scan(path):
    """返回 [(行号, 问题描述), ...]"""
    src = io.open(path, encoding='utf-8').read()
    i, n, line = 0, len(src), 1
    stack = []
    problems = []

    while i < n:
        c = src[i]

        if c == '\n':
            line += 1
            i += 1
            continue

        # 行注释：整段跳过（行尾注释里的中文标点不该报警）
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                i += 1
            continue

        # 块注释
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                if src[i] == '\n':
                    line += 1
                i += 1
            i += 2
            continue

        # 字符串（含三引号）
        if c == '"':
            if src[i:i + 3] == '"""':
                i += 3
                while i + 2 < n and src[i:i + 3] != '"""':
                    if src[i] == '\n':
                        line += 1
                    i += 1
                i += 3
                continue
            i += 1
            while i < n and src[i] != '"':
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == '\n':
                    problems.append((line, '字符串未闭合（跨行到行尾）'))
                    break
                i += 1
            i += 1
            continue

        if c in '([{':
            stack.append((c, line))
            i += 1
            continue

        if c in ')]}':
            if not stack:
                problems.append((line, '多余的 %r' % c))
            elif stack[-1][0] != PAIRS[c]:
                problems.append((line, '%r 与第 %d 行的 %r 不匹配' % (c, stack[-1][1], stack[-1][0])))
                stack.pop()
            else:
                stack.pop()
            i += 1
            continue

        # 到这里说明是普通代码字符 —— 全角标点出现在这里就是错的
        if c in FULLWIDTH:
            problems.append((line, '代码里出现全角字符 %r' % c))
        i += 1

    for c, ln in stack:
        problems.append((ln, '未闭合的 %r' % c))

    return problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join('ios-native', 'VoiceRoom', 'Sources')
    if not os.path.isdir(root):
        print('目录不存在: %s' % root)
        return 2

    files = sorted(glob.glob(os.path.join(root, '**', '*.swift'), recursive=True))
    bad = 0
    for f in files:
        p = scan(f)
        if p:
            bad += 1
            print('!! %s' % f)
            for ln, msg in p[:12]:
                print('     L%d: %s' % (ln, msg))
            if len(p) > 12:
                print('     … 另有 %d 条' % (len(p) - 12))

    print()
    print('扫描 %d 个 Swift 文件，%d 个有问题%s' % (len(files), bad, '' if bad else '  ✅'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())

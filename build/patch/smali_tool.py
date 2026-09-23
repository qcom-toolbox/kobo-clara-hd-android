#!/usr/bin/env python3
"""Apply this port's recorded smali patches to a vendor disassembly.

Every edit asserts on the text it expects to find, so a firmware that does
not match the one this port was developed against fails loudly instead of
producing a subtly broken framework.

subcommands:
  replace-method  <smali-file> <patch-file>   replace whole methods, matched
                                              by their .method signature
  insert-prologue <smali-file> <patch-file>   insert the patch body right
                                              after the method's .prologue
  insert-before   <smali-file> <anchor-file> <patch-file>
                                              insert the patch body before
                                              the (unique) anchor text
  implements      <smali-file> <interface>    add a .implements line after
                                              .super
  replace-text    <smali-file> <old> <new>    literal replacement, must be
                                              unique
"""
import re
import sys

METHOD_RE = re.compile(r'^\.method[^\n]*$', re.M)


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def write(path, text):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def strip_comments(text):
    """Drop our leading '#' commentary lines from a patch file."""
    lines = text.split('\n')
    while lines and (lines[0].startswith('#') or not lines[0].strip()):
        lines.pop(0)
    return '\n'.join(lines)


def split_methods(patch):
    """Yield (signature, full method text) for each method in a patch file."""
    out = []
    cur = None
    for line in strip_comments(patch).split('\n'):
        if line.startswith('.method'):
            cur = [line]
        elif cur is not None:
            cur.append(line)
            if line.strip() == '.end method':
                out.append((cur[0].strip(), '\n'.join(cur)))
                cur = None
    if not out:
        sys.exit('patch file contains no complete .method block')
    return out


def replace_method(target_path, patch_path):
    target = read(target_path)
    for signature, body in split_methods(read(patch_path)):
        start = target.find(signature + '\n')
        if start < 0:
            sys.exit('method not found in %s:\n  %s' % (target_path, signature))
        end = target.find('.end method', start)
        if end < 0:
            sys.exit('unterminated method in %s: %s' % (target_path, signature))
        end += len('.end method')
        if target.count(signature + '\n') != 1:
            sys.exit('method signature is not unique: %s' % signature)
        target = target[:start] + body + target[end:]
        print('  replaced %s' % signature)
    write(target_path, target)


def insert_prologue(target_path, patch_path):
    """The patch file starts with the .method line it belongs to."""
    patch = strip_comments(read(patch_path))
    lines = patch.split('\n')
    signature = lines[0].strip()
    body = '\n'.join(l for l in lines[1:] if l.strip() != '.prologue')
    target = read(target_path)
    if target.count(signature + '\n') != 1:
        sys.exit('method signature is not unique in %s: %s' % (target_path, signature))
    start = target.index(signature + '\n')
    marker = '    .prologue\n'
    at = target.find(marker, start)
    if at < 0:
        sys.exit('no .prologue in %s' % signature)
    at += len(marker)
    if body.strip() and body.strip() in target[start:at + len(body) + 64]:
        print('  already patched: %s' % signature)
        return
    write(target_path, target[:at] + body.rstrip('\n') + '\n' + target[at:])
    print('  inserted prologue into %s' % signature)


def insert_before(target_path, anchor_path, patch_path):
    anchor = strip_comments(read(anchor_path)).strip('\n')
    body = strip_comments(read(patch_path)).rstrip('\n')
    target = read(target_path)
    if body in target:
        print('  already patched: %s' % target_path)
        return
    if target.count(anchor) != 1:
        sys.exit('anchor not unique (%d matches) in %s' % (target.count(anchor), target_path))
    at = target.index(anchor)
    write(target_path, target[:at] + body + '\n' + target[at:])
    print('  inserted %d lines before anchor in %s' % (body.count('\n') + 1, target_path))


def implements(target_path, interface):
    target = read(target_path)
    line = '.implements %s' % interface
    if line in target:
        print('  already implements %s' % interface)
        return
    m = re.search(r'^\.super [^\n]*$', target, re.M)
    if not m:
        sys.exit('no .super line in %s' % target_path)
    at = m.end()
    write(target_path, target[:at] + '\n\n' + line + target[at:])
    print('  %s now implements %s' % (target_path, interface))


def replace_text(target_path, old, new):
    target = read(target_path)
    if new in target and old not in target:
        print('  already patched: %s' % target_path)
        return
    if target.count(old) != 1:
        sys.exit('text not unique (%d matches) in %s' % (target.count(old), target_path))
    write(target_path, target.replace(old, new))
    print('  patched %s' % target_path)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1]
    if cmd == 'replace-method' and len(argv) == 4:
        replace_method(argv[2], argv[3])
    elif cmd == 'insert-prologue' and len(argv) == 4:
        insert_prologue(argv[2], argv[3])
    elif cmd == 'insert-before' and len(argv) == 5:
        insert_before(argv[2], argv[3], argv[4])
    elif cmd == 'implements' and len(argv) == 4:
        implements(argv[2], argv[3])
    elif cmd == 'replace-text' and len(argv) == 5:
        replace_text(argv[2], argv[3], argv[4])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv)

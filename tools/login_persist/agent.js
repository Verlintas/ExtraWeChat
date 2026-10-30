// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

'use strict';

// ExtraWeChat login-persistence agent (experimental).
//
// Hooks owl::v9::ini_file::get in the WeChat process. When ilink2's
// TdiAutoLoginAsync asks for kTdiKeyAutoauthKey / kTdiKeyAutoauthEncKey:
//   - capture a non-empty key and send it to the host (the host stores it);
//   - if the returned key is empty and the host supplied a saved key, write it
//     into the returned std::string so the normal auto-auth path can continue.
//
// This is deliberately diagnostic-friendly: the raw key is only sent to the
// local host process, never printed to stdout by this agent.

const GET_SYM = '__ZN3owl2v98ini_file3getERKNSt3__112basic_stringIcNS2_11char_traitsIcEENS2_9allocatorIcEEEESA_';
const TARGET_KEYS = ['kTdiKeyAutoauthKey', 'kTdiKeyAutoauthEncKey'];

let saved = []; // [{key, value}]
let hooked = false;
let attempts = 0;

send({ type: 'log', message: 'agent loaded, pid=' + Process.id });

function readStdString(p) {
    if (!p || p.isNull()) return '';
    try {
        const long = (p.add(23).readU8() & 0x80) !== 0;
        if (long) {
            const ptr = p.readPointer();
            const len = p.add(8).readU64().toNumber();
            if (ptr.isNull() || len < 0 || len > 1024 * 1024) return '';
            return ptr.readUtf8String(len) || '';
        }
        const len = p.readU8() >> 1;
        if (len < 0 || len > 22) return '';
        return p.add(1).readUtf8String(len) || '';
    } catch (e) {
        return '';
    }
}

function writeStdString(p, value) {
    // Build a libc++ long-string layout in-place. The buffer is allocated with
    // malloc so the app's std::string destructor can free it with operator
    // delete. The previous string's heap buffer (if any) is intentionally
    // leaked: this runs at most once per login key and avoids calling into
    // libc++ destructors from the hook.
    const mallocPtr = Module.findExportByName(null, 'malloc');
    if (!mallocPtr) throw new Error('malloc not found');
    const malloc = new NativeFunction(mallocPtr, 'pointer', ['size_t']);
    const len = value.length;
    const buf = malloc(len + 1);
    if (buf.isNull()) throw new Error('malloc failed');
    buf.writeUtf8String(value);
    p.writePointer(buf);
    p.add(8).writeU64(uint64(len));
    p.add(16).writeU64(uint64(len).or(uint64(1).shl(63)));
}

function log(msg) {
    send({ type: 'log', message: msg });
}

function findAndHook() {
    if (attempts === 0) {
        try {
            const mods = Process.enumerateModules()
                .filter(m => /owl|ilink/i.test(m.name))
                .map(m => m.name);
            send({ type: 'log', message: 'matching modules: ' + mods.join(', ') });
        } catch (e) {
            send({ type: 'log', message: 'enumerateModules failed: ' + e });
        }
    }
    const candidates = [GET_SYM, GET_SYM.replace(/^__/, '_')];
    let addr = null;
    for (const name of candidates) {
        addr = Module.findExportByName(null, name);
        if (addr) break;
        addr = Module.findExportByName('owl', name);
        if (addr) break;
    }
    if (!addr) {
        if (attempts < 10) send({ type: 'log', message: 'ini_file::get export not found yet' });
        attempts++;
        setTimeout(findAndHook, 100);
        return;
    }
    send({ type: 'log', message: 'found ini_file::get at ' + addr });
    Interceptor.attach(addr, {
        onEnter(args) {
            this.sret = this.context.x8;
            this.key = readStdString(args[1]);
            this.isTarget = TARGET_KEYS.indexOf(this.key) >= 0;
        },
        onLeave() {
            if (!this.isTarget) return;
            const current = readStdString(this.sret);
            log(`[ini_file] ${this.key} length=${current.length}`);
            if (current.length > 0) {
                send({ type: 'capture', key: this.key, value: current });
                return;
            }
            const match = saved.find(x => x.key === this.key) || saved[0];
            if (!match || !match.value) return;
            try {
                writeStdString(this.sret, match.value);
                send({ type: 'inject', key: this.key, length: match.value.length });
            } catch (e) {
                log(`[inject] failed: ${e}`);
            }
        }
    });
    hooked = true;
    send({ type: 'ready', address: addr.toString() });
}

rpc.exports = {
    setKeys(keys) {
        saved = keys || [];
        log(`[keys] received ${saved.length} saved key(s)`);
    },
    status() {
        return { hooked: hooked, keys: saved.map(x => ({ key: x.key, length: (x.value || '').length })) };
    }
};

findAndHook();

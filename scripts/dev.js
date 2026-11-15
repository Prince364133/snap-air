#!/usr/bin/env node
/**
 * Snapy Workspace Dev Runner
 *
 * Concurrently launches all apps in the project:
 *  1. [engine]   AI Backend (Python ws://127.0.0.1:8765)
 *  2. [hud]      Desktop Application (Electron HUD overlay)
 *  3. [website]  Web Application & Docs (Astro http://localhost:4321)
 *  4. [mobile]   Android Mobile App (Flutter, optional via --mobile / --all)
 *
 * Automatically handles cross-platform paths, line-prefixed colored logs,
 * and clean process tree termination on Ctrl+C.
 */

const { spawn, execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const readline = require('readline');

const ROOT_DIR = path.resolve(__dirname, '..');
const IS_WIN = process.platform === 'win32';

// Ensure Electron runs as Electron, not as plain Node.js (which happens if IDE has ELECTRON_RUN_AS_NODE set)
delete process.env.ELECTRON_RUN_AS_NODE;

// ANSI Color Helpers
const C = {
    reset: '\x1b[0m',
    bold: '\x1b[1m',
    dim: '\x1b[2m',
    cyan: '\x1b[36m',
    green: '\x1b[32m',
    magenta: '\x1b[35m',
    yellow: '\x1b[33m',
    red: '\x1b[31m',
    blue: '\x1b[34m',
};

const args = process.argv.slice(2);
const wantMobile = args.includes('--mobile') || args.includes('--all');
const engineOnly = args.includes('--engine-only');
const noEngine = args.includes('--no-engine');
const noWeb = args.includes('--no-web');
const noApp = args.includes('--no-app') || args.includes('--no-hud');

// Track all active child processes for clean termination
const activeChildren = new Set();
let shuttingDown = false;

function cleanExit() {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`\n${C.yellow}Shutting down all Snapy apps...${C.reset}`);

    for (const child of activeChildren) {
        if (!child || child.killed) continue;
        try {
            if (IS_WIN) {
                // Kill process tree on Windows
                execSync(`taskkill /F /T /PID ${child.pid}`, { stdio: 'ignore' });
            } else {
                try {
                    process.kill(-child.pid, 'SIGTERM');
                } catch (_) {
                    child.kill('SIGTERM');
                }
            }
        } catch (_) {
            // Process might have already terminated
        }
    }
    process.exit(0);
}

process.on('SIGINT', cleanExit);
process.on('SIGTERM', cleanExit);
process.on('exit', () => {
    if (!shuttingDown) cleanExit();
});

function findPython() {
    const engineDir = path.join(ROOT_DIR, 'engine');
    const venvWin = path.join(engineDir, '.venv', 'Scripts', 'python.exe');
    const venvUnix = path.join(engineDir, '.venv', 'bin', 'python');

    if (IS_WIN && fs.existsSync(venvWin)) return venvWin;
    if (!IS_WIN && fs.existsSync(venvUnix)) return venvUnix;

    return IS_WIN ? 'python' : 'python3';
}

function startProcess(name, color, cmd, cmdArgs, cwd, env = {}) {
    const tag = `${color}${C.bold}[${name}]${C.reset}`;
    console.log(`${tag} Starting in ${path.relative(ROOT_DIR, cwd) || '.'}...`);

    const childEnv = {
        ...process.env,
        ...env,
        FORCE_COLOR: '1',
        PYTHONIOENCODING: 'utf-8',
        PYTHONUNBUFFERED: '1',
    };
    delete childEnv.ELECTRON_RUN_AS_NODE;

    const isDirectExe = cmd.endsWith('.exe');
    const child = isDirectExe
        ? spawn(cmd, cmdArgs, {
              cwd,
              env: childEnv,
              shell: false,
              stdio: ['ignore', 'pipe', 'pipe'],
          })
        : spawn(`${cmd} ${cmdArgs.join(' ')}`.trim(), {
              cwd,
              env: childEnv,
              shell: true,
              stdio: ['ignore', 'pipe', 'pipe'],
          });

    activeChildren.add(child);

    const pipeLines = (stream, isErr = false) => {
        if (!stream) return;
        const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
        rl.on('line', (line) => {
            if (!line.trim()) return;
            const prefix = isErr ? `${tag} ${C.red}ERR${C.reset}:` : `${tag}`;
            console.log(`${prefix} ${line}`);
        });
    };

    pipeLines(child.stdout, false);
    pipeLines(child.stderr, true);

    child.on('error', (err) => {
        console.error(`${tag} ${C.red}Failed to start: ${err.message}${C.reset}`);
        activeChildren.delete(child);
    });

    child.on('exit', (code, signal) => {
        activeChildren.delete(child);
        if (!shuttingDown) {
            const status = signal ? `killed by ${signal}` : `exited with code ${code}`;
            console.log(`${tag} ${C.dim}${status}${C.reset}`);
        }
    });

    return child;
}

// -------------------------------------------------------------------
// Launch Sequence
// -------------------------------------------------------------------

console.log(`${C.bold}=======================================================${C.reset}`);
console.log(`${C.bold}  🚀 Starting Snapy Dev Workspace${C.reset}`);
console.log(`  • ${C.cyan}[engine]${C.reset}  ws://127.0.0.1:8765  (AI Python Backend)`);
if (!engineOnly && !noApp) {
    console.log(`  • ${C.magenta}[hud]${C.reset}     Snapy Desktop HUD    (Electron Overlay Window)`);
}
if (!engineOnly && !noWeb) {
    console.log(`  • ${C.green}[website]${C.reset} http://localhost:4321 (Astro Web App & Docs)`);
}
if (wantMobile) {
    console.log(`  • ${C.yellow}[mobile]${C.reset}  Android App          (Flutter)`);
}
console.log(`${C.dim}  (Press Ctrl+C at any time to stop all apps)${C.reset}`);
console.log(`${C.bold}=======================================================${C.reset}\n`);

// 1. Start AI Engine (Python)
if (!noEngine) {
    const pythonExe = findPython();
    startProcess('engine', C.cyan, pythonExe, ['-u', 'main.py'], path.join(ROOT_DIR, 'engine'));
}

if (engineOnly) return;

// 2. Start Website (Astro)
if (!noWeb) {
    startProcess('website', C.green, 'npm', ['run', 'dev'], path.join(ROOT_DIR, 'website'));
}

// 3. Start Desktop HUD App (Electron)
if (!noApp) {
    setTimeout(() => {
        if (shuttingDown) return;
        startProcess('hud', C.magenta, 'npm', ['start'], path.join(ROOT_DIR, 'app'), {
            SNAP_AIR_EXTERNAL_ENGINE: '1',
        });
    }, 600);
}

// 4. Start Mobile (Flutter, if requested)
if (wantMobile) {
    setTimeout(() => {
        if (shuttingDown) return;
        startProcess('mobile', C.yellow, 'flutter', ['run'], path.join(ROOT_DIR, 'mobile'));
    }, 1200);
}

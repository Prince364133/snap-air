/* Snap's living orb: layered light blobs that move with the assistant's state
   and react to the microphone / voice level. Pure canvas, no dependencies. */
(function () {
    const PALETTES = {
        idle:      [[94, 129, 255], [150, 110, 255], [70, 200, 255]],
        listening: [[40, 200, 255], [60, 255, 200], [120, 160, 255]],
        thinking:  [[170, 90, 255], [255, 90, 200], [90, 120, 255]],
        speaking:  [[90, 170, 255], [190, 220, 255], [130, 110, 255]],
        off:       [[140, 140, 150], [110, 110, 120], [170, 170, 180]],
    };
    const SPEED = { idle: 0.35, listening: 0.9, thinking: 1.8, speaking: 1.1, off: 0.1 };
    const reduceMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const orbs = new Set();

    function lerp(a, b, t) { return a + (b - a) * t; }

    class Orb {
        constructor(canvas) {
            this.c = canvas;
            this.ctx = canvas.getContext('2d');
            this.cssSize = canvas.width;
            const dpr = window.devicePixelRatio || 1;
            canvas.style.width = canvas.style.height = this.cssSize + 'px';
            canvas.width = canvas.height = Math.round(this.cssSize * dpr);
            this.state = 'idle';
            this.level = 0;
            this.smooth = 0;
            this.recording = false;
            this.t = Math.random() * 100;
            this.colors = PALETTES.idle.map((c) => c.slice());
            orbs.add(this);
        }
        setState(s) { this.state = PALETTES[s] ? s : 'idle'; }
        setLevel(l) { this.level = Math.max(0, Math.min(1, l)); }
        setRecording(r) { this.recording = !!r; }

        draw(dt) {
            const { ctx, c } = this;
            const W = c.width, R = W / 2;
            const target = PALETTES[this.state];
            for (let i = 0; i < 3; i++) for (let k = 0; k < 3; k++) this.colors[i][k] = lerp(this.colors[i][k], target[i][k], 0.06);
            this.smooth = lerp(this.smooth, this.level, 0.25);
            const speed = (SPEED[this.state] || 0.4) * (reduceMotion ? 0.25 : 1);
            this.t += dt * speed;
            const pulse = this.state === 'speaking' || this.state === 'listening' ? this.smooth : 0;
            const breathe = 0.03 * Math.sin(this.t * 1.3);

            ctx.clearRect(0, 0, W, W);
            ctx.save();
            const scale = 0.86 + breathe + pulse * 0.14;
            ctx.translate(R, R);
            ctx.scale(scale, scale);
            ctx.beginPath();
            ctx.arc(0, 0, R * 0.98, 0, Math.PI * 2);
            ctx.clip();
            // base
            const base = ctx.createRadialGradient(0, 0, 0, 0, 0, R);
            base.addColorStop(0, 'rgba(255,255,255,0.95)');
            base.addColorStop(1, `rgba(${this.colors[0].map(Math.round).join(',')},0.9)`);
            ctx.fillStyle = base;
            ctx.fillRect(-R, -R, W, W);
            // moving blobs
            ctx.globalCompositeOperation = 'screen';
            for (let i = 0; i < 3; i++) {
                const a = this.t * (0.9 + i * 0.37) + i * 2.1;
                const rr = R * (0.38 + 0.12 * Math.sin(this.t * 0.7 + i));
                const x = Math.cos(a) * rr, y = Math.sin(a * 1.13) * rr;
                const g = ctx.createRadialGradient(x, y, 0, x, y, R * (0.75 + pulse * 0.3));
                const col = this.colors[i].map(Math.round).join(',');
                g.addColorStop(0, `rgba(${col},0.95)`);
                g.addColorStop(1, `rgba(${col},0)`);
                ctx.fillStyle = g;
                ctx.fillRect(-R, -R, W, W);
            }
            // glassy highlight
            ctx.globalCompositeOperation = 'source-over';
            const hl = ctx.createRadialGradient(-R * 0.35, -R * 0.45, 0, -R * 0.35, -R * 0.45, R * 0.7);
            hl.addColorStop(0, 'rgba(255,255,255,0.55)');
            hl.addColorStop(1, 'rgba(255,255,255,0)');
            ctx.fillStyle = hl;
            ctx.fillRect(-R, -R, W, W);
            ctx.restore();
            if (this.recording) {
                ctx.beginPath();
                ctx.arc(R, R, R - Math.max(1.5, W * 0.04), 0, Math.PI * 2);
                ctx.lineWidth = Math.max(2, W * 0.07);
                ctx.strokeStyle = `rgba(255,69,58,${0.65 + 0.35 * Math.sin(this.t * 4)})`;
                ctx.stroke();
            }
        }
    }

    let last = performance.now();
    function frame(now) {
        const dt = Math.min(0.05, (now - last) / 1000);
        last = now;
        for (const o of orbs) {
            if (o.c.offsetParent !== null || o.c.closest('.island')) o.draw(dt);
        }
        requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
    window.Orb = Orb;
})();

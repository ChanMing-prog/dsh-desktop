// 生成 1024x1024 的 DSH 应用图标 PNG（纯 Node，无外部依赖）：
// 圆角方块 + DeepSeek 蓝渐变底 + 白色圆环 + 气泡点。
import { deflateSync } from "node:zlib";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

const SIZE = 1024;
const RADIUS = 232;          // 圆角半径
const CX = 512, CY = 500;    // 圆环圆心
const RING_R = 300;          // 圆环半径
const RING_HALF = 42;        // 圆环半宽
const DOT_DX = 212, DOT_DY = -212; // 气泡点偏移（45° 方向）
const DOT_R = 92;
const TOP = [0x5b, 0x7b, 0xff];     // 顶部渐变色
const BOTTOM = [0x43, 0x59, 0xe6];  // 底部渐变色

function crc32(buf) {
  let table = crc32.table;
  if (!table) {
    table = crc32.table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      table[n] = c;
    }
  }
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = table[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, "ascii");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crc]);
}

function encodePNG(rgba) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(SIZE, 0);
  ihdr.writeUInt32BE(SIZE, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 6;  // color type RGBA
  const stride = SIZE * 4;
  const raw = Buffer.alloc((stride + 1) * SIZE);
  for (let y = 0; y < SIZE; y++) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const idat = deflateSync(raw, { level: 9 });
  return Buffer.concat([sig, chunk("IHDR", ihdr), chunk("IDAT", idat), chunk("IEND", Buffer.alloc(0))]);
}

// 圆角矩形 SDF：< 0 在内部
function roundedRectSDF(x, y) {
  const half = SIZE / 2;
  const qx = Math.abs(x - half) - (half - RADIUS);
  const qy = Math.abs(y - half) - (half - RADIUS);
  const ox = Math.max(qx, 0), oy = Math.max(qy, 0);
  return Math.hypot(ox, oy) + Math.min(Math.max(qx, qy), 0) - RADIUS;
}

const rgba = Buffer.alloc(SIZE * SIZE * 4);
for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const idx = (y * SIZE + x) * 4;
    // 圆角矩形 alpha（1px 抗锯齿）
    const alpha = Math.max(0, Math.min(1, 0.5 - roundedRectSDF(x, y)));
    if (alpha === 0) continue;
    // 纵向渐变
    const t = y / SIZE;
    const r = Math.round(TOP[0] + (BOTTOM[0] - TOP[0]) * t);
    const g = Math.round(TOP[1] + (BOTTOM[1] - TOP[1]) * t);
    const b = Math.round(TOP[2] + (BOTTOM[2] - TOP[2]) * t);
    // 圆环
    const dc = Math.hypot(x - CX, y - CY);
    const ring = Math.abs(dc - RING_R) <= RING_HALF;
    // 气泡点
    const dot = Math.hypot(x - (CX + DOT_DX), y - (CY + DOT_DY)) <= DOT_R;
    const white = ring || dot;
    rgba[idx] = white ? Math.round(255 * alpha) : Math.round(r * alpha);
    rgba[idx + 1] = white ? Math.round(255 * alpha) : Math.round(g * alpha);
    rgba[idx + 2] = white ? Math.round(255 * alpha) : Math.round(b * alpha);
    rgba[idx + 3] = Math.round(255 * alpha);
  }
}

const out = process.argv[2] || "icon-1024.png";
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, encodePNG(rgba));
console.log(`icon written: ${out}`);

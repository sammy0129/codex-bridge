import { constants } from 'node:fs';
import { lstat, open, realpath, stat } from 'node:fs/promises';
import { dirname, relative, resolve } from 'node:path';
import { BridgeError } from '@codex-bridge/protocol';

export const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

export function imageContentType(bytes: Buffer): string {
  if (bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return 'image/png';
  if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return 'image/jpeg';
  if (['GIF87a', 'GIF89a'].includes(bytes.subarray(0, 6).toString('ascii'))) return 'image/gif';
  if (bytes.subarray(0, 4).toString('ascii') === 'RIFF' && bytes.subarray(8, 12).toString('ascii') === 'WEBP') return 'image/webp';
  throw new BridgeError('INVALID_IMAGE', 'Unsupported image format');
}

export async function readReferencedImage(path: string, root: string): Promise<{ bytes: Buffer; contentType: string }> {
  const target = resolve(root, path);
  try {
    const canonical = await realpath(target);
    for (let component = target; ; component = dirname(component)) {
      if ((await lstat(component)).isSymbolicLink()) throw new BridgeError('IMAGE_PATH_CHANGED', 'Linked image paths are not allowed');
      if (dirname(component) === component) break;
    }
    const before = await stat(target);
    if (!before.isFile()) throw new BridgeError('INVALID_IMAGE', 'Image must be a regular file');
    if (before.size > MAX_IMAGE_BYTES) throw new BridgeError('IMAGE_TOO_LARGE', 'Image exceeds 20 MiB');
    const file = await open(target, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0) | (constants.O_NONBLOCK ?? 0));
    try {
      const opened = await file.stat();
      if (!opened.isFile() || before.dev !== opened.dev || before.ino !== opened.ino || before.size !== opened.size || before.mtimeMs !== opened.mtimeMs || relative(canonical, await realpath(target)) !== '') {
        throw new BridgeError('IMAGE_PATH_CHANGED', 'Image changed while opening');
      }
      const buffer = Buffer.alloc(opened.size + 1);
      let length = 0;
      while (length < buffer.length) {
        const result = await file.read(buffer, length, buffer.length - length, null);
        if (result.bytesRead === 0) break;
        length += result.bytesRead;
      }
      const after = await file.stat();
      const current = await stat(target);
      if (length !== opened.size || after.size !== opened.size || after.mtimeMs !== opened.mtimeMs || current.ino !== opened.ino || current.dev !== opened.dev || relative(canonical, await realpath(target)) !== '') {
        throw new BridgeError('IMAGE_PATH_CHANGED', 'Image changed while reading');
      }
      const bytes = buffer.subarray(0, length);
      return { bytes, contentType: imageContentType(bytes) };
    } finally { await file.close(); }
  } catch (error) {
    if (error instanceof BridgeError) throw error;
    throw new BridgeError('IMAGE_UNAVAILABLE', 'Image file is unavailable');
  }
}

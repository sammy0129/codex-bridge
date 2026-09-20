import Fastify from 'fastify';
import websocket from '@fastify/websocket';
import rateLimit from '@fastify/rate-limit';
import { WebSocket } from 'ws';
import { BridgeError, PROTOCOL_VERSION, object, text, parseRequest, errorPayload, type ObjectMap, type BridgeEvent } from '@codex-bridge/protocol';
import { Controller } from './controller.js';
import { tls, type Config } from './config.js';

export async function createServer(controller: Controller, config: Config) {
  const app = Fastify({ https: await tls(config), logger: false, bodyLimit: 29 * 1024 * 1024 });
  await app.register(rateLimit, { max: 120, timeWindow: 60_000 });
  await app.register(websocket, { options: { maxPayload: 2 * 1024 * 1024 } });
  const device = (request: any): string => {
    const authorization = request.headers.authorization;
    const id = typeof authorization === 'string' && authorization.startsWith('Bearer ') ? controller.store.authenticate(authorization.slice(7)) : undefined;
    if (!id) throw new BridgeError('UNAUTHORIZED', 'Device is not paired or was revoked');
    return id;
  };
  app.setErrorHandler((error, _request, reply) => {
    const payload = errorPayload(error);
    reply.code(payload.code === 'UNAUTHORIZED' ? 401 : payload.code === 'INTERNAL_ERROR' ? ((error as any).statusCode ?? 500) : 400).send({ error: payload });
  });
  app.get('/v1/health', async request => { device(request); return { ok: true, ready: controller.codex.ready }; });
  app.get('/v1/info', async request => { device(request); return controller.info(); });
  app.post('/v1/pair', { config: { rateLimit: { max: 5, timeWindow: 60_000 } } }, async request => {
    const params = object(request.body);
    if (params.acceptFullAccess !== true) throw new BridgeError('CONSENT_REQUIRED', 'Explicitly acknowledge host access before pairing');
    return { ...controller.store.pair(text(params.code, 'code', 128), text(params.deviceName, 'deviceName', 100)), info: controller.info() };
  });
  app.post('/v1/devices/revoke', async request => {
    device(request);
    const params = object(request.body);
    controller.store.revoke(text(params.deviceId, 'deviceId', 128));
    return {};
  });
  app.post('/v1/uploads', async (request, reply) => {
    const deviceId = device(request);
    const params = object(request.body);
    const result = await controller.request(deviceId, {
      type: 'request', requestId: text(params.requestId, 'requestId', 128), method: 'files/upload',
      params: { projectId: text(params.projectId, 'projectId', 128), dataBase64: text(params.dataBase64, 'image', 28 * 1024 * 1024) },
    });
    return result.error ? reply.code(400).send({ error: result.error }) : result.result;
  });
  app.get('/v1/thread-images', async (request, reply) => {
    device(request);
    const query = object(request.query);
    const index = text(query.contentIndex, 'contentIndex', 12);
    if (!/^(0|[1-9][0-9]*)$/.test(index)) throw new BridgeError('INVALID_PARAMS', 'Invalid contentIndex');
    const image = await controller.threadImage({ ...query, contentIndex: Number(index) });
    device(request);
    return reply.header('Cache-Control', 'private, no-store').header('X-Content-Type-Options', 'nosniff').type(image.contentType).send(image.bytes);
  });
  app.get('/v1/ws', { websocket: true, preValidation: async request => { device(request); } }, (socket, request) => {
    const deviceId = device(request);
    let initialized = false;
    let requests = 0;
    let intervalStart = Date.now();
    const send = (value: unknown): void => {
      if (socket.readyState !== WebSocket.OPEN) return;
      if (socket.bufferedAmount > 8 * 1024 * 1024) { socket.close(1013, 'Slow reader: reconnect for replay'); return; }
      socket.send(JSON.stringify(value));
    };
    const onEvent = (event: BridgeEvent): void => { if (initialized && controller.store.deviceActive(deviceId)) send(event); };
    controller.on('event', onEvent);
    const keepalive = setInterval(() => {
      if (!controller.store.deviceActive(deviceId)) socket.close(4001, 'Device revoked');
      else socket.ping();
    }, 15_000);
    const handshakeTimer = setTimeout(() => { if (!initialized) socket.close(4000, 'Handshake required'); }, 10_000);
    socket.on('message', raw => {
      void (async () => {
        if (!controller.store.deviceActive(deviceId)) { socket.close(4001, 'Device revoked'); return; }
        let envelope: ObjectMap;
        try { envelope = object(JSON.parse(raw.toString())); } catch { socket.close(4000, 'Invalid JSON'); return; }
        if (!initialized) {
          if (envelope.type !== 'hello' || envelope.protocolVersion !== PROTOCOL_VERSION) { socket.close(4002, 'Protocol version mismatch'); return; }
          const cursor = Number.isSafeInteger(envelope.afterSeq) && envelope.afterSeq >= 0 ? envelope.afterSeq : 0;
          const events = controller.store.replay(cursor);
          const highWater = controller.store.cursor();
          const reset = envelope.epoch !== controller.store.epoch || cursor > highWater || events.length > 50_000 || (events.length > 0 && events[0]!.seq > cursor + 1);
          send({ type: 'hello', ...controller.info(), reset, cursor: highWater, runtime: controller.store.runtime() });
          if (!reset) for (const event of events) send(event);
          send({ type: 'synced', epoch: controller.store.epoch, cursor: highWater });
          initialized = true; clearTimeout(handshakeTimer);
          return;
        }
        if (Date.now() - intervalStart > 60_000) { intervalStart = Date.now(); requests = 0; }
        if (++requests > 2000) { socket.close(4008, 'Request rate exceeded'); return; }
        try { send(await controller.request(deviceId, parseRequest(envelope))); }
        catch (error) { send({ type: 'response', requestId: envelope.requestId, error: errorPayload(error) }); }
      })().catch(() => socket.close(1011, 'Request failed'));
    });
    socket.on('close', () => { clearInterval(keepalive); clearTimeout(handshakeTimer); controller.off('event', onEvent); });
  });
  return app;
}

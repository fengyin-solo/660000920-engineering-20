import type { PiniaPluginContext } from 'pinia';

/**
 * 值班进度持久化：
 * - 把 store 状态写入 localStorage，刷新页面后恢复，不影响当前值班进度；
 * - 仅持久化数据，不持久化定时器/播放句柄等运行时字段；
 * - 不引入任何新依赖，手动启动方式无需改变；
 * - 数据损坏或结构不兼容时自动丢弃旧快照，回到内置初始状态。
 */

const STORAGE_KEY = 'iot-monitor:state:v1';

// 运行时字段（定时器 id 等）不可序列化，恢复时不应写回
const RUNTIME_KEYS = new Set(['playbackInterval', 'mockAlertInterval']);

function isPlainSerializable(value: unknown): boolean {
  if (value === null || value === undefined) return true;
  const t = typeof value;
  if (t === 'string' || t === 'number' || t === 'boolean') return true;
  if (t !== 'object') return false;
  if (Array.isArray(value)) return value.every(isPlainSerializable);
  return Object.values(value as Record<string, unknown>).every(isPlainSerializable);
}

export function persistencePlugin({ store }: PiniaPluginContext) {
  // 恢复快照
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) {
      const snapshot = JSON.parse(raw) as Record<string, unknown>;
      const partial: Record<string, unknown> = {};
      for (const key of Object.keys(store.$state)) {
        if (RUNTIME_KEYS.has(key)) continue;
        if (Object.prototype.hasOwnProperty.call(snapshot, key)) {
          partial[key] = snapshot[key];
        }
      }
      if (Object.keys(partial).length > 0) {
        store.$patch((state) => {
          Object.assign(state, partial);
        });
      }
    }
  } catch {
    // 快照损坏（旧版本/手工篡改）：忽略，使用内置初始数据
    localStorage.removeItem(STORAGE_KEY);
  }

  // 变更后写回（Pinia 动作或 $patch 都会触发）
  store.$subscribe(() => {
    try {
      const snapshot: Record<string, unknown> = {};
      for (const [key, value] of Object.entries(store.$state)) {
        if (RUNTIME_KEYS.has(key)) continue;
        if (isPlainSerializable(value)) {
          snapshot[key] = value;
        }
      }
      localStorage.setItem(STORAGE_KEY, JSON.stringify(snapshot));
    } catch {
      // 存储满或隐私模式：静默降级为内存态，不影响页面功能
    }
  });
}

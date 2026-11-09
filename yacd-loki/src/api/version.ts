import { getURLAndInit } from '~/misc/request-helper';
import { ClashAPIConfig } from '~/types';

type VersionData = {
  version?: string;
  premium?: boolean;
  meta?: boolean;
};

/** Raw GET /version, for callers that need the status and error body rather than a fallback. */
export function requestVersion(apiConfig: ClashAPIConfig, signal?: AbortSignal) {
  const { url, init } = getURLAndInit(apiConfig);
  return fetch(url + '/version', { ...init, signal });
}

export async function fetchVersion(
  endpoint: string,
  apiConfig: ClashAPIConfig,
): Promise<VersionData> {
  let json = {};
  try {
    const { url, init } = getURLAndInit(apiConfig);
    const res = await fetch(url + endpoint, init);
    if (res.ok) {
      json = await res.json();
    }
  } catch (err) {
    // log and ignore

    console.log(`failed to fetch ${endpoint}`, err);
  }
  return json;
}

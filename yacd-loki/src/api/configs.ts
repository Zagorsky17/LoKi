import { getURLAndInit } from '~/misc/request-helper';
import { ClashAPIConfig } from '~/types';

const endpoint = '/configs';

export async function fetchConfigs(apiConfig: ClashAPIConfig, signal?: AbortSignal) {
  const { url, init } = getURLAndInit(apiConfig);
  return await fetch(url + endpoint, { ...init, signal });
}

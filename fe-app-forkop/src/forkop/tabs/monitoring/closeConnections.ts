import { Forkop } from '../../types';

// Closing all connections at once also resets the core's network, so a filter's connections are
// closed one by one, a few requests at a time.
// Leave one of the session's three RPC slots for the Monitoring or Logs read.
const PARALLEL_CLOSES = 2;

export async function closeConnections(
  ids: string[],
  close: (id: string) => Promise<Forkop.MethodResponse<unknown>>,
): Promise<{ closed: string[]; failed: string[] }> {
  const closed: string[] = [];
  const failed: string[] = [];

  for (let start = 0; start < ids.length; start += PARALLEL_CLOSES) {
    const batch = ids.slice(start, start + PARALLEL_CLOSES);
    const results = await Promise.all(
      batch.map((id) => close(id).catch(() => null)),
    );

    results.forEach((result, index) => {
      (result?.success ? closed : failed).push(batch[index]);
    });
  }

  return { closed, failed };
}

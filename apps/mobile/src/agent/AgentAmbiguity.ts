/**
 * Which uncertainty an `ambiguous` Agent journal is carrying.
 *
 * The journal has one `ambiguous` phase and three things that set it: a tool
 * execution whose outcome is unknown, a provider round whose answer never
 * came, and a cancellation that could not tell whether its tool target ran.
 * They say different things to the person. An ambiguous *round* means a
 * request may have reached the service; an ambiguous *execution* means a tool
 * may already have changed their files -- the second is the one that should
 * send them to check the workspace before retrying.
 *
 * The phase alone cannot tell them apart, and neither can the round lineage:
 * an ambiguous cancellation marks the lineage ambiguous too, although a
 * cancellation can only be ambiguous about a tool. What does tell them apart
 * is the batch. Every path that leaves a tool's outcome unknown records that
 * tool's receipt with the outcome `ambiguous`; a round that never answered
 * has no such receipt, because it never produced a call to settle.
 */

type AmbiguityJournal = {
  readonly phase: string;
  readonly batch: readonly { readonly receipt: { readonly outcome: string } | null }[];
};

export function agentAmbiguityCode(
  journal: AmbiguityJournal,
): 'E_AGENT_ROUND_AMBIGUOUS' | 'E_AGENT_EXECUTION_AMBIGUOUS' {
  return journal.batch.some(call => call.receipt?.outcome === 'ambiguous')
    ? 'E_AGENT_EXECUTION_AMBIGUOUS'
    : 'E_AGENT_ROUND_AMBIGUOUS';
}

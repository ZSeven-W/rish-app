import { agentAmbiguityCode } from '../src/agent/AgentAmbiguity';

/**
 * An ambiguous journal says one of two very different things, and the batch
 * is what decides which. The phase cannot, and neither can the round lineage:
 * an ambiguous cancellation marks the lineage ambiguous although it can only
 * ever be unsure about a tool.
 */
describe('agentAmbiguityCode', () => {
  const journal = (outcomes: readonly (string | null)[]) => ({
    phase: 'ambiguous',
    batch: outcomes.map(outcome => ({ receipt: outcome === null ? null : { outcome } })),
  });

  test('a round that never produced a call is the round\'s own uncertainty', () => {
    expect(agentAmbiguityCode(journal([]))).toBe('E_AGENT_ROUND_AMBIGUOUS');
  });

  test('calls that settled or never ran leave the round as the uncertain part', () => {
    expect(agentAmbiguityCode(journal(['ok', 'failed', null]))).toBe('E_AGENT_ROUND_AMBIGUOUS');
  });

  /**
   * The one that must never be softened. If a tool may have run, the person
   * has to be told to check their files before retrying, whatever else the
   * journal looks like.
   */
  test('any call whose outcome is unknown makes it an execution uncertainty', () => {
    expect(agentAmbiguityCode(journal(['ambiguous']))).toBe('E_AGENT_EXECUTION_AMBIGUOUS');
    expect(agentAmbiguityCode(journal(['ok', null, 'ambiguous']))).toBe('E_AGENT_EXECUTION_AMBIGUOUS');
  });
});

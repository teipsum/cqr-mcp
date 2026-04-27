#!/usr/bin/env python3
"""
Grafeo data dump pre-processor.

Workaround for a bug in `grafeo data load` (0.5.40 CLI): the load step
compacts node IDs (assigns fresh sequential IDs starting at 0) but does
not remap edge source/target endpoint IDs. Any edge whose endpoint
references an ID that was a gap in the source ID space silently becomes
unreachable in the loaded DB.

This script reads a grafeo JSON-Lines dump, builds a stable old_id ->
new_id map for nodes (compacting gaps), and rewrites every node id and
every edge source/target with the new IDs. Output is a fresh JSON-Lines
dump that the CLI's `data load` can ingest with no remapping required
(because there are no gaps).

Usage:
  compact_dump.py <input_dump.json> <output_dump.json>

Guarantees:
  - Node count preserved
  - Edge count preserved
  - Every edge source/target points to a real node ID in the output
  - Node ordering preserved (input ID order maps to output 0..N-1)
"""
import json
import sys
from collections import Counter

def main():
    if len(sys.argv) != 3:
        print('usage: compact_dump.py <input> <output>', file=sys.stderr)
        sys.exit(2)
    in_path, out_path = sys.argv[1], sys.argv[2]

    nodes = []
    edges = []
    other = []
    with open(in_path) as f:
        for line in f:
            r = json.loads(line)
            t = r.get('type')
            if t == 'node':
                nodes.append(r)
            elif t == 'edge':
                edges.append(r)
            else:
                other.append(r)

    print(f'Read {len(nodes)} nodes, {len(edges)} edges, {len(other)} other from {in_path}')

    # Sort nodes by old ID to preserve relative ordering
    nodes.sort(key=lambda n: n['id'])

    # Build old_id -> new_id map
    id_map = {}
    for new_id, n in enumerate(nodes):
        old_id = n['id']
        id_map[old_id] = new_id

    # Validate: every edge endpoint must exist in id_map
    dangling = [e for e in edges if e['source'] not in id_map or e['target'] not in id_map]
    if dangling:
        print(f'ERROR: input dump has {len(dangling)} dangling edges (endpoints not in node set)', file=sys.stderr)
        by_type = Counter(e['edge_type'] for e in dangling)
        for k, v in by_type.most_common():
            print(f'  {k}: {v}', file=sys.stderr)
        sys.exit(1)

    # Rewrite
    with open(out_path, 'w') as out:
        for o in other:
            out.write(json.dumps(o) + '\n')
        for n in nodes:
            n2 = dict(n)
            n2['id'] = id_map[n['id']]
            out.write(json.dumps(n2) + '\n')
        for e in edges:
            e2 = dict(e)
            e2['source'] = id_map[e['source']]
            e2['target'] = id_map[e['target']]
            # Some edge records carry an 'id' field too; preserve relative ordering by reusing rank
            out.write(json.dumps(e2) + '\n')

    print(f'Wrote {len(nodes)} nodes, {len(edges)} edges to {out_path}')
    print(f'ID compaction: old range {min(id_map)}..{max(id_map)} ({len(id_map)} nodes, {max(id_map)-min(id_map)+1-len(id_map)} gaps)')
    print(f'                new range 0..{len(nodes)-1} (dense)')

if __name__ == '__main__':
    main()

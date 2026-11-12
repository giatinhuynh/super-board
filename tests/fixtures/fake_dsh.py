#!/usr/bin/env python3
# Stubbed `dsh headless` for the offline DeepSeek Harness lane/wave suites; set by SB_DSH_TEST_* env vars.
# It answers the way a chat model does: prose and a ```json fence around the lane result,
# with a decoy JSON example before it, so the launcher's extraction is exercised.
import fcntl, json, os, re, sys, time
from pathlib import Path
args = sys.argv[1:]
prompt = sys.stdin.read()
patches = [args[i + 1] for i, arg in enumerate(args) if arg == '--patch']
card = json.loads(re.search(r'^Card: (.+)$', prompt, re.M).group(1))
lane = re.search(r'Run super-(build|qa|review)', prompt).group(1)
with open(os.environ['SB_DSH_TEST_LOG'], 'a') as log:
    fcntl.flock(log, fcntl.LOCK_EX)
    counter = Path(os.environ['SB_DSH_TEST_LOG'] + '.active')
    active = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(active))
    # Overlay files live in the launcher's temp dir, so record their text now.
    log.write(json.dumps(dict(args=args, cwd=os.getcwd(), prompt=prompt, number=card['number'], lane=lane, active=active,
                              patches={path: Path(path).read_text() for path in patches})) + '\n')
time.sleep(float(os.environ.get('SB_DSH_TEST_DELAY', '0')))
print('dsh: reasoning: stub thinking goes to stderr', file=sys.stderr)
status = os.environ.get('SB_DSH_TEST_STATUS', 'advanced')
column = {'build': 'QA', 'qa': 'Review', 'review': 'Done'}[lane] if status == 'advanced' else card['status']
result = dict(status=status, column=column, detail=os.environ.get('SB_DSH_TEST_DETAIL', 'stub lane result'),
              prUrl=None, branch=None, priorFindings=None)
if 'SB_DSH_TEST_ANSWER' in os.environ:
    print(os.environ['SB_DSH_TEST_ANSWER'])
else:
    print('Done. The schema asks for {"status": "...", "column": "..."}; here is the result:\n\n```json\n'
          + json.dumps(result, indent=2) + '\n```\n\nThe card moved on.')
with open(os.environ['SB_DSH_TEST_LOG'], 'a') as log:
    fcntl.flock(log, fcntl.LOCK_EX)
    counter.write_text(str(int(counter.read_text()) - 1))
sys.exit(int(os.environ.get('SB_DSH_TEST_EXIT', '0')))

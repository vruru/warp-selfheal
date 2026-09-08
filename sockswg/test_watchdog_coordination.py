#!/usr/bin/env python3
"""Rootless A/B watchdog coordination tests; never invokes real systemctl."""
import os,pathlib,subprocess,tempfile,unittest

ROOT=pathlib.Path(__file__).resolve().parent
class CoordinationTests(unittest.TestCase):
 def run_case(self,script,timer_active=True,disabled=False,delegate_rc=0):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp);bin=p/'bin';bin.mkdir();state=p/'state';state.mkdir()
   (p/'active').write_text('b\n');(p/'settings').write_text('')
   if disabled:(state/'disabled').touch()
   commands={
    'systemctl':'#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_LOG"\n[ "$*" = "is-active --quiet sockswg-bluegreen-check.timer" ] || exit 91\nexit '+('0' if timer_active else '3')+'\n',
    'bluegreen':'#!/bin/sh\nprintf "delegate:%s\\n" "$*" >> "$TEST_LOG"\nexit '+str(delegate_rc)+'\n'}
   for name,content in commands.items():
    f=bin/name;f.write_text(content);f.chmod(0o700)
   env=dict(os.environ,STATE_DIR=str(state),SETTINGS_FILE=str(p/'settings'),WATCHDOG_PATH=str(bin)+':/usr/bin:/bin',BLUEGREEN_ACTIVE_FILE=str(p/'active'),BLUEGREEN_SCRIPT=str(bin/'bluegreen'),TEST_LOG=str(p/'log'))
   result=subprocess.run(['bash',str(script)],env=env,capture_output=True,text=True)
   log=(p/'log').read_text() if (p/'log').exists() else ''
   return result.returncode,log
 def test_active_timer_owns_repair_for_both_modes(self):
  for script in [ROOT/'sockswg-watchdog',ROOT/'direct/sockswg-watchdog']:
   with self.subTest(script=str(script)):
    rc,log=self.run_case(script)
    self.assertEqual(rc,0);self.assertNotIn('restart',log);self.assertNotIn('delegate:',log)
 def test_missing_timer_delegates_to_same_owner(self):
  for script in [ROOT/'sockswg-watchdog',ROOT/'direct/sockswg-watchdog']:
   rc,log=self.run_case(script,timer_active=False)
   self.assertEqual(rc,0);self.assertIn('delegate:check',log);self.assertNotIn('restart',log)
 def test_delegated_failure_propagates(self):
  for script in [ROOT/'sockswg-watchdog',ROOT/'direct/sockswg-watchdog']:
   rc,log=self.run_case(script,timer_active=False,delegate_rc=7)
   self.assertEqual(rc,7);self.assertIn('delegate:check',log)
 def test_disabled_still_has_priority(self):
  for script in [ROOT/'sockswg-watchdog',ROOT/'direct/sockswg-watchdog']:
   rc,log=self.run_case(script,disabled=True)
   self.assertEqual((rc,log),(0,''))

if __name__=='__main__':unittest.main()

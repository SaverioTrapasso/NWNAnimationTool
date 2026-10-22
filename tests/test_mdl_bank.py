"""Run with python -m unittest discover -s tests (standard library only)."""
import os,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'mdl_bank'))
import bridge

FIRST='''newanim attack demo
length 1
transtime 0.25
animroot rootdummy
event 0.5 impact
node dummy rootdummy
parent demo
orientationkey 2
0 0 0 1 0
1 0 0 1 0.2
alphakey 2
0 0
1 1
endnode
node dummy extra
parent rootdummy
scalekey 2
0 1
1 2
endnode
doneanim attack demo'''
SECOND=FIRST.replace('attack','idle')
MODEL='''newmodel demo
setsupermodel demo NULL
classification CHARACTER
beginmodelgeom demo
node dummy demo
parent NULL
endnode
endmodelgeom demo
'''+FIRST+'\n'+SECOND+'\ndonemodel demo\n'
def exported(angle='0.2',length='1'):
    return f'''newanim attack a_ba_non_combat
length {length}
node dummy rootdummy
parent a_ba_non_combat
orientationkey
0 0 0 1 0
{length} 0 0 1 {angle}
endlist
endnode
doneanim attack a_ba_non_combat
'''

class BankTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=os.environ.get('NWN_TEST_TMP'));self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.source=self.root/'demo.mdl';self.source.write_text(MODEL)
        self.session=self.root/'session'
        self.opened=bridge.open_bank({'source':str(self.source),'session':str(self.session)})
    def stage(self,edited,baseline=None):
        a=self.root/'edited.txt';b=self.root/'baseline.txt'
        a.write_text(edited);b.write_text(baseline or exported())
        return bridge.stage_clip({'session':str(self.session),'animation':'attack','edited':str(a),'baseline':str(b)})
    def test_preview_rig_matches_supermodel(self):
        self.assertEqual(bridge.preview_rig(MODEL.replace('demo NULL','demo an_a_fa')), 'female')
        self.assertEqual(bridge.preview_rig(MODEL.replace('demo NULL','demo an_a_ba')), 'male')
        self.assertEqual(bridge.preview_rig(MODEL), '')
    def test_inventory_and_noop(self):
        self.assertEqual([c['name'] for c in self.opened['clips']],['attack','idle'])
        self.stage(exported())
        self.assertEqual((self.session/'working.mdl').read_text(),MODEL)
    def test_changed_rotation_preserves_other_content(self):
        self.stage(exported('0.5'))
        text=(self.session/'working.mdl').read_text()
        self.assertIn(SECOND,text)
        self.assertIn('event 0.5 impact',text)
        self.assertIn('alphakey 2\n0 0\n1 1',text)
        self.assertIn('1 0 0 1 0.5',text)
        self.assertEqual(self.source.read_text(),MODEL)
        self.assertEqual(text.split('newanim')[0],MODEL.split('newanim')[0])
    def test_duration_retimes_events_and_unedited_channels(self):
        self.stage(exported('0.2','2'))
        text=(self.session/'working.mdl').read_text()
        self.assertIn('event 1 impact',text)
        self.assertIn('scalekey 2\n0 1\n2 2',text)
        self.assertIn(SECOND,text)
    def test_existing_output_unchanged_on_invalid_export_name(self):
        out=self.root/'wrong.mdl';out.write_bytes(b'keep this')
        with self.assertRaisesRegex(ValueError,'original model filename'):
            bridge.export_bank({'session':str(self.session),'output':str(out)})
        self.assertEqual(out.read_bytes(),b'keep this')
    def test_duplicate_names_rejected(self):
        with self.assertRaisesRegex(ValueError,'Duplicate'):
            bridge.list_clips(FIRST+'\n'+FIRST)

if __name__=='__main__':unittest.main()

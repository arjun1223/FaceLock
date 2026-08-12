# Third-party notices

## AdaFace

FaceLock bundles the 65,150,912-parameter AdaFace IR101 WebFace12M model from
[CVLFace](https://github.com/mk-minchul/CVLface), converted locally to Core ML from the
[official model release](https://huggingface.co/minchul/cvlface_adaface_ir101_webface12m).
The original AdaFace project is at <https://github.com/mk-minchul/AdaFace>. The model
card requires users to follow the training dataset's license; FaceLock is therefore
presented only as a local portfolio/research demo, not as a commercial security product.

The bundled `AdaFace_IR101.mlpackage` contains a local Core ML conversion of the
generic AdaFace IR101 WebFace12M weights. It contains no FaceLock user's camera image,
face embedding, or enrollment profile. FaceLock does not claim ownership of the
upstream weights.

The AdaFace and CVLFace source repositories are MIT-licensed. The official model card
also says to cite the original paper and follow the license of the WebFace12M training
dataset. Those weight/dataset conditions are separate from FaceLock's own MIT license
and are not overridden by it.

AdaFace paper citation:

```bibtex
@inproceedings{kim2022adaface,
  title={AdaFace: Quality Adaptive Margin for Face Recognition},
  author={Kim, Minchul and Jain, Anil K. and Liu, Xiaoming},
  booktitle={Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition},
  year={2022}
}
```

MIT License

Copyright (c) 2022 Minchul Kim

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## HasBrain/FaceUnlock

FaceLock's paced HID-system CGEvent injector, lock-state cross-check, and wake/input
trigger design are adapted from [HasBrain/FaceUnlock](https://github.com/HasBrain/FaceUnlock).

MIT License

Copyright (c) 2026 HasBrain

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

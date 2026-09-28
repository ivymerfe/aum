#!/bin/bash

./build.sh

killall aum
tccutil reset Accessibility me.yami.aum
open aum.app

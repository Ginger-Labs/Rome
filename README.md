# cocoapods-rome

Rome makes it easy to build a list of frameworks. We have heavily modified this README and the tool to suit our own purposes. For orignal documentation see https://github.com/CocoaPods/Rome

## Installation

Use the following process to build and install this gem.

```bash
$ bundle install
$ gem build cocoapods-rome.gemspec
$ sudo gem install cocoapods-rome-1.1.0.gem
```

Steps for building binary pods and incorporating them into the app are in the Notability repo.

You may need to run the following to get the gem to work:
```
$ sudo xcode-select -s /Applications/Xcode.app/Contents/Developer 
$ brew install ruby
```

The first is if the xcode is only pointed at command line tools and not the full xcode install.
The latter is for m1 machines, ffi and other gems don't work otherwise.

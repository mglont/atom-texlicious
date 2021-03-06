# TODO: Logger for https://atom.io/docs/api/v0.176.0/Atom#instance-inDevMode.

fs = require 'fs'
path = require 'path'
extend = require 'extend'

{CompositeDisposable} = require 'atom'

ProcessManager = require './process-manager'
Latexmk = require './latexmk'
MagicComments = require './magic-comments'
MainView = require './views/main-view'
LogTool = require './log-tool'
Watcher = require './watcher'

class TeXlicious
  config:
    texPath:
      title: 'TeX Path'
      description: "Location of your custom TeX installation bin."
      type: 'string'
      default: ''
      order: 1
    texFlavor:
      title: 'TeX Flavor'
      description: 'Default program used to compile a TeX file.'
      type: 'string'
      default: 'pdflatex'
      enum: ['lualatex', 'pdflatex', 'xelatex']
      order: 2
    texInputs:
      title: 'TeX Packages'
      description: "Location of your custom TeX packages directory."
      type: 'string'
      default: ''
      order: 3
    outputDirectory:
      title: 'Output Directory'
      description: 'Output directory relative to the project root.'
      type: 'string'
      default: ''
      order: 4
    bibtexEnabled:
      title: 'Enable BibTeX'
      type: 'boolean'
      default: false
      order: 5
    synctexEnabled:
      title: 'Enable Synctex'
      type: 'boolean'
      default: false
      order: 6
    shellEscapeEnabled:
      title: 'Enable Shell Escape'
      type: 'boolean'
      default: false
      order: 7
    watchDelay:
      title: 'Watch Delay'
      description: 'Time in seconds to wait until compiling when in watch mode.'
      type: 'integer'
      default: 5
      order: 8

  constructor: ->
    # Helpers
    @processManager = new ProcessManager()
    @latexmk = new Latexmk({texliciousCore: @})
    @magicComments = new MagicComments({texliciousCore: @})
    @logTool = new LogTool({texliciousCore: @})

    @mainView = new MainView({texliciousCore: @})
    @watcher = new Watcher({texliciousCore: @, mainView: @mainView})

    # Globals (set them explicitly for readability)
    @texEditor = null
    @texFile = null
    @errorMarkers = [] # TODO: Make this a composite disposable.
    @errors = []
    @watching = false

  activate: (state) ->
    atom.commands.add 'atom-text-editor',
      'texlicious:compile': =>
        unless @isTex()
          return

        unless @mainPanel.isVisible()
          @mainPanel.show()

        @setTex()
        @compile()

    atom.commands.add 'atom-text-editor',
      'texlicious:watch': =>
        unless @isTex()
          return

        unless @mainPanel.isVisible()
          @mainPanel.show()

        @setTex()
        @watch()

    atom.commands.add 'atom-text-editor',
      'texlicious:stop': => @stop()

    @mainPanel = atom.workspace.addBottomPanel
      item: @mainView
      visible: false

  deactivate: ->
    @mainPanel.destroy()

  # TODO: See: https://atom.io/docs/v0.176.0/advanced/serialization.
  # serialize: ->

  notify: (message) ->
    atom.notifications.addInfo(message)

  setTex: ->
    activeTextEditor = atom.workspace.getActiveTextEditor()
    activeFile = activeTextEditor.getPath()

    for directory in atom.project.getDirectories()
      if activeFile.indexOf(directory.realPath) isnt -1
        @texProjectRoot = directory.realPath
        break

    unless @texProjectRoot
      return

    # Returns the active item if it is an instance of TextEditor.
    @texEditor = activeTextEditor
  getTexProjectRoot: ->
    @texProjectRoot

  getTexEditor: ->
    @texEditor

  getTexFile: ->
    @texEditor.getPath()

  getPanes: ->
    atom.workspace.getPanes()

  getPaneItems: ->
    atom.workspace.getPaneItems()

  getEditors: ->
    atom.workspace.getTextEditors()

  getBuffers: ->
    (pane.buffer for pane in @getPaneItems())

  getErrors: ->
    @errors

  isTex: ->
    activeFile = atom.workspace.getActiveTextEditor().getPath()
    unless path.extname(activeFile) is '.tex'
      @notify "The file \'" + path.basename activeFile + "\' is not a TeX file."
      return false

    true

  isWatching: ->
    @watching

  isWatchingAndWatched: ->
    if @watching and @texEditor.watched
      true
    else
      false

  setWatching: (bool) ->
    @watching = bool
    @texEditor.watching = bool

  setWatchingAndWatched: (bool) ->
    @watching = bool
    @texEditor.watched = bool

  saveAll: ->
    pane.saveItems() for pane in @getPanes()

  makeArgs: ->
    args = []

    latexmkArgs = @latexmk.args @texEditor.getPath()
    magicComments = @magicComments.getMagicComments @texEditor.getPath()
    mergedArgs = extend(true, latexmkArgs, magicComments)

    @texFile = mergedArgs.root

    args.push mergedArgs.default
    if mergedArgs.synctex?
      args.push mergedArgs.synctex
    if mergedArgs.program?
      args.push mergedArgs.program
    if mergedArgs.outdir?
      args.push mergedArgs.outdir
    args.push mergedArgs.root

    args

  # TODO: Update editor gutter when file is opened.
  updateGutters: ->
    editors =  @getEditors()

    for error in @errors
      for editor in editors
        errorFile = path.basename error.file
        if errorFile == path.basename editor.getPath()
          row = parseInt error.line - 1
          column = editor.buffer.lineLengthForRow(row)
          range = [[row, 0], [row, column]]
          marker = editor.markBufferRange(range, invalidate: 'touch')
          decoration = editor.decorateMarker(marker, {type: 'gutter', class: 'gutter-red'})
          @errorMarkers.push marker
  movePDF: ->
    outputDirectory = atom.config.get('texlicious.outputDirectory')
    if outputDirectory isnt ''
      oldPath = path.join(@getTexProjectRoot(), outputDirectory)
      outputFiles = fs.readdirSync(oldPath)
      for file in outputFiles
        if path.extname(file) is '.pdf'
          fs.renameSync(oldPath + '/' + file, @getTexProjectRoot() + '/' + file)

  compile: ->
    console.log "Compiling ..."

    @saveAll()

    args = @makeArgs()
    options = @processManager.options()

    @mainView.toggleCompileIndicator()
    proc = @latexmk.make args, options, (exitCode) =>
      @mainView.toggleCompileIndicator()
      switch exitCode
        when 0
          console.log '... done compiling.'
          marker.destroy() for marker in @errorMarkers
          @errors.length = 0
          @movePDF()

        else
          console.log '... error compiling.'
          @errors = @logTool.getErrors(@texFile)

      @updateGutters()
      @mainView.updateErrorView()

  watch: ->
    if @isWatching()
      @notify "Changed watched file to " + "#{path.basename @getTexFile()}"

    @setWatchingAndWatched(true)
    @watcher.startWatching()

  stop: ->
    if @isWatchingAndWatched()
      @watcher.stopWatching()
    else
      @notify "You are not watching a file."

module.exports = new TeXlicious()

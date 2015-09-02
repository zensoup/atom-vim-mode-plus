# Refactoring status: 90%
Delegato = require 'delegato'
_ = require 'underscore-plus'
{Emitter, CompositeDisposable} = require 'atom'

settings = require './settings'

Operators   = require './operators'
Motions     = require './motions'
TextObjects = require './text-objects'
InsertMode  = require './insert-mode'
Scroll      = require './scroll'

OperationStack  = require './operation-stack'
CountManager    = require './count-manager'
MarkManager     = require './mark-manager'
ModeManager     = require './mode-manager'
RegisterManager = require './register-manager'

Developer = null # delay

module.exports =
class VimState
  Delegato.includeInto(this)

  editor: null
  operationStack: null
  destroyed: false
  replaceModeListener: null
  developer: null
  locked: false
  lastOperation: null

  # Mode handling is delegated to modeManager
  delegatingMethods = [
    'isNormalMode'
    'isInsertMode'
    'isOperatorPendingMode'
    'isVisualMode'
    'activateNormalMode'
    'activateInsertMode'
    'activateOperatorPendingMode'
    'activateReplaceMode'
    'replaceModeUndo'
    'deactivateInsertMode'
    'deactivateVisualMode'
    'activateVisualMode'
    'resetNormalMode'
    'resetVisualMode'
    'setInsertionCheckpoint'
  ]
  delegatingProperties = [
    'mode'
    'submode'
  ]
  @delegatesProperty delegatingProperties..., toProperty: 'modeManager'
  @delegatesMethods delegatingMethods..., toProperty: 'modeManager'

  constructor: (@editorElement, @statusBarManager, @globalVimState) ->
    @emitter = new Emitter
    @subscriptions = new CompositeDisposable
    @editor = @editorElement.getModel()
    @history = []
    @subscriptions.add @editor.onDidDestroy =>
      @destroy()

    @count = new CountManager(this)
    @mark = new MarkManager(this)
    @register = new RegisterManager(this)
    @operationStack = new OperationStack(this)
    @modeManager = new ModeManager(this)

    handleSelectionChange = _.debounce =>
      return unless @editor?
      if @editor.getSelections().every((s) -> s.isEmpty())
        @activateNormalMode() if @isVisualMode()
      else
        @activateVisualMode('characterwise') if @isNormalMode()
    , 100

    @subscriptions.add @editor.onDidChangeSelectionRange handleSelectionChange

    @subscriptions.add @editor.onDidChangeCursorPosition ({cursor}) =>
      @dontPutCursorAtEndOfLine(cursor)
    @subscriptions.add @editor.onDidAddCursor @dontPutCursorAtEndOfLine.bind(this)

    @editorElement.classList.add("vim-mode")
    @init()
    if settings.get('startInInsertMode')
      @activateInsertMode()
    else
      @activateNormalMode()

  destroy: ->
    return if @destroyed
    @destroyed = true
    @emitter.emit 'did-destroy'
    @subscriptions.dispose()
    if @editor.isAlive()
      @deactivateInsertMode()
      @editorElement.component?.setInputEnabled(true)
      @editorElement.classList.remove("vim-mode")
      @editorElement.classList.remove("normal-mode")
    @editor = null
    @editorElement = null
    @lastOperation = null

  onDidFailToCompose: (fn) ->
    @emitter.on('failed-to-compose', fn)

  onDidDestroy: (fn) ->
    @emitter.on('did-destroy', fn)

  registerCommands: (commands) ->
    for name, fn of commands
      do (fn) =>
        @subscriptions.add atom.commands.add(@editorElement, "vim-mode:#{name}", fn)

  # Register operation command.
  # command-name is automatically mapped to correspoinding class.
  # e.g.
  #   join -> Join
  #   scroll-down -> ScrollDown
  registerOperationCommands: (kind, names) ->
    commands = {}
    for name in names
      do (name) =>
        klass = _.capitalize(_.camelize(name))
        commands[name] = =>
          try
            @operationStack.push new kind[klass](this)
          catch error
            @lastOperation = null
            throw error unless error.isOperationAbortedError?()
    @registerCommands(commands)

  # Initialize all of vim-mode' commands.
  init: ->
    @registerCommands
      'activate-normal-mode': => @activateNormalMode()
      'activate-linewise-visual-mode': => @activateVisualMode('linewise')
      'activate-characterwise-visual-mode': => @activateVisualMode('characterwise')
      'activate-blockwise-visual-mode': => @activateVisualMode('blockwise')
      'reset-normal-mode': => @resetNormalMode()
      'set-count': (e) => @count.set(e) # 0-9
      'set-register-name': => @register.setName() # "
      'reverse-selections': => @reverseSelections() # o
      'undo': => @undo() # u
      'replace-mode-backspace': => @replaceModeUndo()

    @registerOperationCommands InsertMode, [
      'insert-register'
      'copy-from-line-above', 'copy-from-line-below'
    ]

    @registerOperationCommands TextObjects, [
      'select-inside-word', 'select-a-word',
      'select-inside-whole-word', 'select-a-whole-word',
      'select-inside-double-quotes'  , 'select-around-double-quotes',
      'select-inside-single-quotes'  , 'select-around-single-quotes',
      'select-inside-back-ticks'     , 'select-around-back-ticks',
      'select-inside-paragraph'      , 'select-around-paragraph',
      'select-inside-comment'        , 'select-around-comment',
      'select-inside-indent'         , 'select-around-indent',
      'select-inside-curly-brackets' , 'select-around-curly-brackets',
      'select-inside-angle-brackets' , 'select-around-angle-brackets',
      'select-inside-square-brackets', 'select-around-square-brackets',
      'select-inside-parentheses'    , 'select-around-parentheses',
      'select-inside-tags'           , # why not around version exists?,
    ]

    @registerOperationCommands Motions, [
      'move-to-beginning-of-line',
      'repeat-find', 'repeat-find-reverse',
      'move-down', 'move-up', 'move-left', 'move-right',
      'move-to-next-word'     , 'move-to-next-whole-word',
      'move-to-end-of-word'   , 'move-to-end-of-whole-word',
      'move-to-previous-word' , 'move-to-previous-whole-word',
      'move-to-next-paragraph', 'move-to-previous-paragraph',
      'move-to-first-character-of-line', 'move-to-last-character-of-line',
      'move-to-first-character-of-line-up', 'move-to-first-character-of-line-down',
      'move-to-first-character-of-line-and-down',
      'move-to-last-nonblank-character-of-line-and-down',
      'move-to-start-of-file', 'move-to-line',
      'move-to-top-of-screen', 'move-to-bottom-of-screen', 'move-to-middle-of-screen',
      'scroll-half-screen-up', 'scroll-half-screen-down',
      'scroll-full-screen-up', 'scroll-full-screen-down',
      'repeat-search'          , 'repeat-search-backwards',
      'move-to-mark'           , 'move-to-mark-literal',
      'find'                   , 'find-backwards',
      'till'                   , 'till-backwards',
      'search'                 , 'reverse-search',
      'search-current-word'    , 'reverse-search-current-word',
      'bracket-matching-motion',
    ]

    @registerOperationCommands Operators, [
      'activate-insert-mode', 'insert-after',
      'activate-replace-mode',
      'substitute', 'substitute-line',
      'insert-at-beginning-of-line', 'insert-after-end-of-line',
      'insert-below-with-newline', 'insert-above-with-newline',
      'delete', 'delete-to-last-character-of-line',
      'delete-right', 'delete-left',
      'change', 'change-to-last-character-of-line',
      'yank', 'yank-line',
      'put-after', 'put-before',
      'upper-case', 'lower-case', 'toggle-case', 'toggle-case-now',
      'camelize', 'underscore', 'dasherize',
      'surround', 'delete-surround', 'change-surround',
      'join',
      'indent', 'outdent', 'auto-indent',
      'increase', 'decrease',
      'repeat', 'mark', 'replace',
      'replace-with-register'
      'toggle-line-comments'
    ]

    @registerOperationCommands Scroll, [
      'scroll-down', 'scroll-up',
      'scroll-cursor-to-top', 'scroll-cursor-to-top-leave',
      'scroll-cursor-to-middle', 'scroll-cursor-to-middle-leave',
      'scroll-cursor-to-bottom', 'scroll-cursor-to-bottom-leave',
      'scroll-cursor-to-left', 'scroll-cursor-to-right',
    ]

    # Load developer helper commands.
    if atom.inDevMode()
      Developer ?= require './developer'
      @developer = new Developer(this)
      @developer.init()

  # Miscellaneous commands
  # -------------------------
  undo: ->
    @editor.undo()
    @activateNormalMode()

  reverseSelections: ->
    reversed = not @editor.getLastSelection().isReversed()
    for selection in @editor.getSelections()
      selection.setBufferRange(selection.getBufferRange(), {reversed})

  # Search History
  # -------------------------
  pushSearchHistory: (search) -> # should be saveSearchHistory for consistency.
    @globalVimState.searchHistory.unshift search

  getSearchHistoryItem: (index = 0) ->
    @globalVimState.searchHistory[index]

  withLock: (callback) ->
    try
      @locked = true
      callback()
    finally
      @locked = false

  isLocked: ->
    @locked

  dontPutCursorAtEndOfLine: (cursor) ->
    return if @isLocked() or not @isNormalMode()
    if @editor.getPath()?.endsWith 'tryit.coffee'
      return
    if cursor.isAtEndOfLine() and not cursor.isAtBeginningOfLine()
      @withLock ->
        {goalColumn} = cursor
        cursor.moveLeft()
        cursor.goalColumn = goalColumn

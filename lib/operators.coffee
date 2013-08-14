_ = require 'underscore'

class OperatorError
  constructor: (@message) ->
    @name = "Operator Error"

class Operator
  vimState: null
  motion: null
  complete: null
  selectOptions: null

  # selectOptions - The options object to pass through to the motion when
  #                 selecting.
  constructor: (@editor, @vimState, {@selectOptions}={}) ->
    @complete = false

  # Public: Determines when the command can be executed.
  #
  # Returns true if ready to execute and false otherwise.
  isComplete: -> @complete

  # Public: Marks this as ready to execute and saves the motion.
  #
  # motion - The motion used to select what to operate on.
  #
  # Returns nothing.
  compose: (motion) ->
    if not motion.select
      throw new OperatorError("Must compose with a motion")

    @motion = motion
    @complete = true


  # Protected: Wraps the function within an single undo step.
  #
  # fn - The function to wrap.
  #
  # Returns nothing.
  undoTransaction: (fn) ->
    @editor.getBuffer().transact(fn)
#
# It deletes everything selected by the following motion.
#
class Delete extends Operator
  allowEOL: null

  # allowEOL - Determines whether the cursor should be allowed to rest on the
  #            end of line character or not.
  constructor: (@editor, @vimState, {@allowEOL, @selectOptions}={}) ->
    @complete = false

  # Public: Deletes the text selected by the given motion.
  #
  # count - The number of times to execute.
  #
  # Returns nothing.
  execute: (count=1) ->
    cursor = @editor.getCursor()

    @undoTransaction =>
      _.times count, =>
        if _.last(@motion.select(1, @selectOptions))
          @editor.getSelection().delete()

        @editor.moveCursorLeft() if !@allowEOL and cursor.isAtEndOfLine() and !@motion.isLinewise?()

      if @motion.isLinewise?()
        @editor.setCursorScreenPosition([cursor.getScreenRow(), 0])

#
# It changes everything selected by the following motion.
#
class Change extends Operator
  # Public: Changes the text selected by the given motion.
  #
  # count - The number of times to execute.
  #
  # Returns nothing.
  execute: (count=1) ->
    operator = new Delete(@editor, @vimState, allowEOL: true, selectOptions: {excludeWhitespace: true})
    operator.compose(@motion)
    operator.execute(count)

    @vimState.activateInsertMode()

#
# It copies everything selected by the following motion.
#
class Yank extends Operator
  register: '"'

  # Public: Copies the text selected by the given motion.
  #
  # count - The number of times to execute.
  #
  # Returns nothing.
  execute: (count=1) ->
    text = ""
    type = if @motion.isLinewise then 'linewise' else 'character'
    originalPosition = @editor.getCursorScreenPosition()

    _.times count, =>
      if _.last(@motion.select())
        text += @editor.getSelection().getText()

    @vimState.setRegister(@register, {text, type})

    if @motion.isLinewise?()
      @editor.setCursorScreenPosition(originalPosition)
    else
      @editor.clearSelections()

#
# It indents everything selected by the following motion.
#
class Indent extends Operator
  # Public: Indents the text selected by the given motion.
  #
  # count - The number of times to execute.
  #
  # Returns nothing.
  execute: (count=1) ->
    @indent(count)

  # Protected: Indents or outdents the text selected by the given motion.
  #
  # count  - The number of times to execute.
  # direction - Either 'indent' or 'outdent'
  #
  # Returns nothing.
  indent: (count, direction='indent') ->
    row = @editor.getCursorScreenRow()

    @motion.select(count)
    if direction == 'indent'
      @editor.indentSelectedRows()
    else if direction == 'outdent'
      @editor.outdentSelectedRows()

    @editor.setCursorScreenPosition([row, 0])
    @editor.moveCursorToFirstCharacterOfLine()

#
# It outdents everything selected by the following motion.
#
class Outdent extends Indent
  # Public: Indents the text selected by the given motion.
  #
  # count - The number of times to execute.
  #
  # Returns nothing.
  execute: (count=1) ->
    @indent(count, 'outdent')

#
# It pastes everything contained within the specifed register
#
class Put extends Operator
  direction: 'after'
  register: '"'
  location: null

  constructor: (@editor, @vimState, {@location, @selectOptions}={}) -> @complete = true

  # Public: Pastes the text in the given register.
  #
  # count - The number of times to execute.
  #
  # Returns nothing.
  execute: (count=1) ->
    {text, type} = @vimState.getRegister(@register) || {}
    return unless text

    @undoTransaction =>
      _.times count, =>
        if type == 'linewise' and @location == 'after'
          @editor.moveCursorDown()
        else if @location == 'after'
          @editor.moveCursorRight()

        @editor.moveCursorToBeginningOfLine() if type == 'linewise'
        @editor.insertText(text)

        if type == 'linewise'
          @editor.moveCursorUp()
          @editor.moveCursorToFirstCharacterOfLine()

#
# It combines the current line with the following line.
#
class Join extends Operator
  constructor: (@editor, @vimState, {@selectOptions}={}) -> @complete = true

  # Public: Combines the current with the following lines
  #
  # count - The number of times to execute.
  #
  # Returns nothing.
  execute: (count=1) ->
    @undoTransaction =>
      _.times count, =>
        @editor.joinLine()

module.exports = { OperatorError, Delete, Yank, Put, Join, Indent, Outdent, Change }

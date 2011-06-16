/*
 * Copyright 2011 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.spicefactory.lib.command.base {

import org.spicefactory.lib.command.*;
import org.spicefactory.lib.command.data.CommandData;
import org.spicefactory.lib.command.data.DefaultCommandData;
import org.spicefactory.lib.command.events.CommandEvent;
import org.spicefactory.lib.command.events.CommandExecutorFailure;
import org.spicefactory.lib.command.events.CommandResultEvent;
import org.spicefactory.lib.command.lifecycle.CommandLifecycle;
import org.spicefactory.lib.command.lifecycle.DefaultCommandLifecycle;
import org.spicefactory.lib.command.util.CommandUtil;
import org.spicefactory.lib.errors.IllegalStateError;
import org.spicefactory.lib.logging.LogContext;
import org.spicefactory.lib.logging.Logger;
import org.spicefactory.lib.util.collection.List;

/**
 * Abstract base class for CommandGroup implementations.
 * Manages multiple child commands and is itself a command (Composite Design Pattern)
 * so that it can be nested within other groups or flows.
 * 
 * @author Jens Halm
 */
public class AbstractCommandExecutor extends AbstractSuspendableCommand implements CommandExecutor {
		
		
	private static var logger:Logger = LogContext.getLogger(AbstractCommandExecutor);
	
	
	private var activeCommands:List = new List();
	
	private var _data:DefaultCommandData = new DefaultCommandData();
	
	private var _lifecycle:CommandLifecycle;
	
	private var processErrors:Boolean;
	private var processCancellations:Boolean;
	
	
	/**
	 * 
	 */
	function AbstractCommandExecutor (description:String = null, 
			processErrors:Boolean = false, processCancellations:Boolean = false) {
		super(description);
		this.processErrors = processErrors;
		this.processCancellations = processCancellations;
	}

	/**
	 * @inheritDoc
	 */
	public function get cancellable () : Boolean {
		for each (var com:Command in activeCommands) {
			if (!CommandUtil.isCancellable(com)) return false;
		}
		return true;
	}

	/**
	 * @inheritDoc
	 */	
	public function get suspendable () : Boolean {
		for each (var com:Command in activeCommands) {
			if (!CommandUtil.isSuspendable(com)) return false;
		}
		return true;
	}
	
	/**
	 * @inheritDoc
	 */
	public function prepare (lifecycle:CommandLifecycle, data:CommandData) : void {
		_lifecycle = lifecycle;
		_data = new DefaultCommandData(data);	
	}
	
	protected function get lifecycle () : CommandLifecycle {
		if (!_lifecycle) {
			_lifecycle = createLifecycle();
		}
		return _lifecycle;
	}
	
	protected function createLifecycle () : CommandLifecycle {
		return new DefaultCommandLifecycle();
	}
    
    /**
     * The data associated with this executor.
     * Contains any results from previously executed commands or
     * data specified upfront.
     */
    protected function get data () : CommandData {
    	if (!_data) {
    		var newData:CommandData = createData();
    		_data = (newData is DefaultCommandData) 
    			? newData as DefaultCommandData
    			: new DefaultCommandData(newData);
    	}
    	return _data;
    }
    
    protected function createData () : CommandData {
    	return new DefaultCommandData();
    }
    
	/**
	 * Executes the specified command.
	 * 
	 * @param com the command to execute
	 */
	protected function executeCommand (com:Command) : void {
		if (activeCommands.contains(com)) return;
		
		activeCommands.add(com);

		if (com is AsyncCommand) {
			var async:AsyncCommand = com as AsyncCommand;
			addListeners(async);
			if (async.active) return;
		}
		
		if (com is CommandExecutor) {
			CommandExecutor(com).prepare(lifecycle, data);
		}
		
		try {
			lifecycle.beforeExecution(com, data);
			com.execute();
		}
		catch (e:Error) {
			activeCommands.remove(com);
			commandError(com, e);
			return;
		}
		
		if (!(com is AsyncCommand)) {
			activeCommands.remove(com);
			var result:CommandResult = DefaultCommandResult.forCompletion(com, null);
			lifecycle.afterCompletion(com, result);
			commandComplete(result);
		}
	}
	
	private function addListeners (com:AsyncCommand) : void {
		com.addEventListener(CommandResultEvent.COMPLETE, commandCompleteHandler, false, -1);
		com.addEventListener(CommandResultEvent.ERROR, commandErrorHandler, false, -1);
		com.addEventListener(CommandEvent.CANCEL, commandCancelledHandler, false, -1);
	}
	
	private function removeListeners (com:AsyncCommand) : void {
		com.removeEventListener(CommandResultEvent.COMPLETE, commandCompleteHandler);
		com.removeEventListener(CommandResultEvent.ERROR, commandErrorHandler);
		com.removeEventListener(CommandEvent.CANCEL, commandCancelledHandler);
	}
	
	private function removeActiveCommand (com:AsyncCommand, result:CommandResult) : void {
		if (suspended) {
			throw new IllegalStateError("Child command " + com 
					+ " completed while executor was suspended");
		}
		removeListeners(com);
		activeCommands.remove(com);
		lifecycle.afterCompletion(com, result);
	}

	private function commandCompleteHandler (event:CommandResultEvent) : void {
		var com:AsyncCommand = event.target as AsyncCommand;
		removeActiveCommand(com, event);
		_data.addValue(event.value);
		commandComplete(event);
	}
	
	/**
	 * Invoked when a child command has completed its operation.
	 * This includes cancellations or (in case the <code>ignoreChildErrors</code>
	 * property is set to true) also children that failed to complete successfully.
	 * In case of cancellations or errors the result property is null.
	 * 
	 * @param com the command that has completed its operation
	 * @param result the result of the command in case of successful completion
	 */
	protected function commandComplete (result:CommandResult) : void {
		/* default implementation does nothing */ 
	}
	
	private function commandErrorHandler (event:CommandResultEvent) : void {
		var com:AsyncCommand = event.target as AsyncCommand;
		removeActiveCommand(com, event);
		commandError(com, event.value);
	}
	
	private function commandError (com:Command, cause:Object) : void {
		if (processErrors) {
			commandComplete(DefaultCommandResult.forError(com, cause));
		} else {
			doCancel();
			error(new CommandExecutorFailure(this, com, cause));
		}
	}
	
	private function commandCancelledHandler (event:CommandEvent) : void {
		var com:AsyncCommand = event.target as AsyncCommand;
		var result:CommandResult = DefaultCommandResult.forCancellation(com);
		removeActiveCommand(com, result);
		if (processCancellations) {
			commandComplete(result);
		}
		else {
			cancel();
		}
	}
	
	/**
	 * @private
	 */
	protected override function complete (result:Object = undefined) : void {
		if (result === undefined) {
			result = data;
		}
 		super.complete(result);
	}

	/**
	 * @private
	 */
	public override function suspend () : void {
		if (!suspendable) throw new IllegalStateError("Command group '" + this + "' cannot be suspended");
 		super.suspend();
	}
	
	/**
	 * @private
	 */	
	public override function cancel () : void {
		if (!cancellable) throw new IllegalStateError("Command group '" + this + "' cannot be cancelled");
		super.cancel();
	}
	
	/**
	 * @private
	 */
	protected override function doSuspend () : void {
		for each (var com:SuspendableCommand in activeCommands) {
			if (!com.suspended) com.suspend();
		}
	}
	
	/**
	 * @private
	 */
	protected override function doResume () : void {
		for each (var com:SuspendableCommand in activeCommands) {
			if (com.suspended) com.resume();
		}
	}
	
	/**
	 * @private
	 */
	protected override function doCancel () : void {
		for each (var com:AsyncCommand in activeCommands) {
			removeListeners(AsyncCommand(com));
			if (CommandUtil.isCancellable(com)) {
				CancellableCommand(com).cancel();
			}
		}
		activeCommands.removeAll();
	}
	
		
}
	
}
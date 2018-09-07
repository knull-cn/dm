// Copyright 2018 PingCAP, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// See the License for the specific language governing permissions and
// limitations under the License.

package master

import (
	"fmt"

	"github.com/juju/errors"
	"github.com/pingcap/tidb-enterprise-tools/dm/ctl/common"
	"github.com/spf13/cobra"
	"golang.org/x/net/context"
)

// NewCheckTaskCmd creates a CheckTask command
func NewCheckTaskCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "check-task <config_file>",
		Short: "check a task with config file",
		Run:   checkTaskFunc,
	}
	return cmd
}

// checkTaskFunc does check task request
func checkTaskFunc(cmd *cobra.Command, _ []string) {
	if len(cmd.Flags().Args()) != 1 {
		fmt.Println(cmd.Usage())
		return
	}
	content, err := common.GetFileContent(cmd.Flags().Arg(0))
	if err != nil {
		common.PrintLines("get file content error:\n%v", errors.ErrorStack(err))
		return
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// precheck task
	err = checkTask(ctx, string(content))
	if err != nil {
		common.PrintLines("precheck failed %s", errors.ErrorStack(err))
		return
	}

	common.PrintLines("check pass!!!")
}

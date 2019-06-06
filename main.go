package main

import (
	"fmt"
	"os"

	"github.com/ian-howell/airshipctl/cmd"
)

func main() {
	rootCmd, settings, err := cmd.NewRootCmd(os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stdout, err)
		os.Exit(1)
	}

	cmd.AddDefaultAirshipCTLCommands(rootCmd, settings)

	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stdout, err)
		os.Exit(1)
	}
}

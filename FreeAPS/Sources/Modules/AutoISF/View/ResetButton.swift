import SwiftUI

struct ResetButton: View {
    let title: String
    let message: String
    let action: () -> Void
    @State private var showDialog = false

    var body: some View {
        Button(role: .destructive) {
            showDialog = true
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .confirmationDialog("Are you sure?", isPresented: $showDialog, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { action() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

//
//  ResetButton.swift
//  FreeAPS
//
//  Created by Abdulrahman Alfantokh on 14/09/2025.
//

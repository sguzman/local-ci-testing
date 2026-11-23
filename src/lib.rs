/// The output shared by the application and its tests.
pub fn greeting() -> &'static str {
    "Hello from local-ci-testing!"
}

#[cfg(test)]
mod tests {
    use super::greeting;

    #[test]
    fn greeting_is_stable() {
        assert_eq!(greeting(), "Hello from local-ci-testing!");
    }
}
